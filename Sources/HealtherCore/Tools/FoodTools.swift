import Foundation

enum FoodTools {
    static let all: [any AgentTool] = [
        SearchFoodTool(), LookupBarcodeTool(), DraftMealTool(), ConfirmMealTool(), DeleteMealTool(), GetMealsTool(), SavePersonalFoodTool(),
    ]

    static let per100gSchema = Schema.object([
        "kcal": Schema.number("千卡"), "protein": Schema.number("蛋白质 g"), "fat": Schema.number("脂肪 g"),
        "carbs": Schema.number("碳水 g"), "fiber": Schema.number("膳食纤维 g，可选"), "sodium_mg": Schema.number("钠 mg，可选"),
    ], required: ["kcal", "protein", "fat", "carbs"])
}

struct SearchFoodTool: AgentTool {
    let name = "search_food"
    let description = "在营养数据库中查食物（每100g营养）。来源：personal=用户自己吃过/保存的；tw_fda=台湾食品营养成分库（中文，中式/亚洲食物）；usda=美国农业部（英文）；off=Open Food Facts 包装食品。建议同时传中文和英文名。"
    let parameters = Schema.object([
        "queries": Schema.array(Schema.string("食物名"), "1–4 个查询词，例如 [\"番茄炒蛋\", \"scrambled eggs tomato\"]"),
        "limit": Schema.integer("返回条数，默认 8", minimum: 1, maximum: 15),
        "include_online": Schema.boolean("同时联网查 Open Food Facts（包装食品/品牌产品时用，较慢）"),
    ], required: ["queries"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let queries = (args["queries"]?.arrayValue?.compactMap(\.stringValue) ?? [args["queries"]?.stringValue].compactMap { $0 })
            .prefix(4).map { $0 }
        guard !queries.isEmpty else { return .error("queries 不能为空") }
        let results = await ctx.services.foodSearch.search(
            queries: queries, limit: args["limit"]?.intValue ?? 8, includeOnline: args["include_online"]?.boolValue ?? false)
        let o: JSONValue = [
            "results": .array(results.map(\.json)),
            "hint": results.isEmpty ? "没找到，可换个说法或英文再查；仍没有就估算 per100g" : "选最贴近的 food_id 用于 draft_meal",
        ]
        return ToolResult(o, summary: "查了「\(queries.joined(separator: " / "))」，找到 \(results.count) 条")
    }
}

struct LookupBarcodeTool: AgentTool {
    let name = "lookup_barcode"
    let description = "用条形码查包装食品（Open Food Facts，需联网）。"
    let parameters = Schema.object(["barcode": Schema.string("EAN/UPC 数字")], required: ["barcode"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let code = args["barcode"]?.stringValue ?? ""
        guard let c = try await ctx.services.barcode.barcode(code) else {
            return ToolResult(["found": false], summary: "条码 \(code) 没查到")
        }
        return ToolResult(["found": true, "food": c.json], summary: "条码查到：\(c.name)")
    }
}

struct DraftMealTool: AgentTool {
    let name = "draft_meal"
    let description = "创建或更新一餐的草稿（App 中显示为待确认卡片）。每项给 food_id（来自 search_food）或 per100g（估算）。营养由系统按克数计算，不要自己算。更新已有草稿时传 draft_id 并给出完整 items。"
    let parameters = Schema.object([
        "draft_id": Schema.string("更新已有草稿时填写"),
        "meal_type": Schema.string("餐次，默认按时间推断", enum: MealType.allCases.map(\.rawValue)),
        "eaten_at": Schema.string("进食时间，HH:mm 或 YYYY-MM-DD HH:mm，默认现在"),
        "note": Schema.string("备注，如“公司食堂”"),
        "items": Schema.array(Schema.object([
            "name": Schema.string("给用户看的名字，如“米饭”"),
            "grams": Schema.number("克数（可食部分）"),
            "food_id": Schema.string("search_food 返回的 food_id"),
            "per100g": FoodTools.per100gSchema,
            "confidence": Schema.string("对份量和识别的把握", enum: ["high", "medium", "low"]),
            "note": Schema.string("如“按少油估计”"),
        ], required: ["name", "grams"]), "食物列表"),
    ], required: ["items"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let s = ctx.services
        var meal: Meal
        if let ref = args["draft_id"]?.stringValue, !ref.isEmpty {
            guard let existing = try s.meals.find(ref) else { return .error("找不到草稿 \(ref)") }
            meal = existing
        } else {
            let at = ctx.clock.parse(args["eaten_at"]?.stringValue, relativeTo: ctx.now) ?? ctx.now
            meal = Meal(type: MealType.guess(at: at, clock: ctx.clock), eatenAt: at, items: [], photo: ctx.attachments.first?.file)
        }
        if let t = args["meal_type"]?.stringValue.flatMap(MealType.init(rawValue:)) { meal.type = t }
        if let at = ctx.clock.parse(args["eaten_at"]?.stringValue, relativeTo: ctx.now) { meal.eatenAt = at }
        if let note = args["note"]?.stringValue { meal.note = note }
        if meal.photo == nil { meal.photo = ctx.attachments.first?.file }

        var items: [MealItem] = []
        var problems: [String] = []
        for raw in args["items"]?.arrayValue ?? [] {
            guard let name = raw["name"]?.stringValue, let grams = raw["grams"]?.doubleValue, grams > 0 else {
                problems.append("缺少 name/grams 的项被跳过")
                continue
            }
            let confidence = Confidence(rawValue: raw["confidence"]?.stringValue ?? "") ?? .medium
            if let fid = raw["food_id"]?.stringValue, !fid.isEmpty {
                if let food = await s.foodSearch.lookup(id: fid) {
                    items.append(MealItem(name: name, grams: grams, foodID: food.id, source: food.source, per100g: food.per100g,
                                          confidence: confidence, note: raw["note"]?.stringValue))
                    continue
                }
                problems.append("food_id \(fid) 不存在")
            }
            if let n = Nutrients(json: raw["per100g"]) {
                items.append(MealItem(name: name, grams: grams, foodID: nil, source: .estimate, per100g: n,
                                      confidence: raw["confidence"] == nil ? .low : confidence, note: raw["note"]?.stringValue))
            } else {
                problems.append("「\(name)」既没有有效 food_id 也没有 per100g，未加入")
            }
        }
        guard !items.isEmpty else { return .error("没有可用的食物项：" + problems.joined(separator: "；")) }
        meal.items = items
        meal.status = .draft
        meal.updatedAt = ctx.now
        try s.meals.save(meal)

        var o = meal.json(clock: ctx.clock)
        if case .object(var d) = o {
            d["draft_id"] = .string(meal.shortID)
            if !problems.isEmpty { d["problems"] = .array(problems.map(JSONValue.string)) }
            d["next"] = "把总热量和主要构成简短告诉用户，请 TA 确认或修改；确认后调用 confirm_meal"
            o = .object(d)
        }
        return ToolResult(o, summary: "草稿：\(meal.type.displayName) \(fmt(meal.totals.kcal)) kcal", events: [.mealUpdated(meal)])
    }
}

struct ConfirmMealTool: AgentTool {
    let name = "confirm_meal"
    let description = "用户确认后，把草稿正式记入饮食记录（并写入 Apple 健康），同时把这些食物学习进用户的个人食物库。"
    let parameters = Schema.object(["draft_id": Schema.string("草稿 id")], required: ["draft_id"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let s = ctx.services
        guard let ref = args["draft_id"]?.stringValue, var meal = try s.meals.find(ref) else { return .error("找不到这条草稿") }
        meal.status = .confirmed
        meal.updatedAt = ctx.now
        try s.meals.save(meal)
        try ConfirmMealTool.learn(meal, s.personalFoods, now: ctx.now)
        var synced = false
        do {
            try await s.health.save(meal: meal)
            try s.meals.markSynced(meal.id)
            synced = true
        } catch {
            // Local record is the source of truth; HealthKit sync can be retried later.
        }
        let dayTotal = try s.meals.totals(from: ctx.clock.startOfDay(meal.eatenAt), to: ctx.clock.endOfDay(meal.eatenAt))
        let o: JSONValue = [
            "ok": true, "meal": meal.json(clock: ctx.clock), "day_total": dayTotal.json, "synced_to_apple_health": .bool(synced),
            "daily_kcal_goal": JSONValue(s.wellbeing.goal(.dailyKcal)?.target),
        ]
        return ToolResult(o, summary: "已记录\(meal.type.displayName) \(fmt(meal.totals.kcal)) kcal", events: [.mealUpdated(meal)])
    }

    /// Each confirmed item becomes (or reinforces) a personal food with the user's real portion.
    static func learn(_ meal: Meal, _ lib: PersonalFoodLibrary, now: Date) throws {
        for item in meal.items {
            try lib.upsert(name: item.name, per100g: item.per100g, grams: item.grams, countUse: true,
                           sourceRef: item.foodID ?? item.source.rawValue, now: now)
        }
    }
}

struct DeleteMealTool: AgentTool {
    let name = "delete_meal"
    let description = "删除一条饮食记录或草稿（用户说记错了/没吃）。"
    let parameters = Schema.object(["meal_id": Schema.string("meal_id 或 draft_id")], required: ["meal_id"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let s = ctx.services
        guard let ref = args["meal_id"]?.stringValue, let meal = try s.meals.find(ref) else { return .error("找不到这条记录") }
        try s.meals.delete(meal.id)
        if meal.status == .confirmed { try? await s.health.deleteMeal(id: meal.id) }
        var gone = meal
        gone.items = []
        return ToolResult(["ok": true, "deleted": .string(meal.shortID)], summary: "删除了\(meal.type.displayName)记录", events: [.mealUpdated(gone)])
    }
}

struct GetMealsTool: AgentTool {
    let name = "get_meals"
    let description = "查询某段时间的饮食记录明细（每餐每项）。"
    let parameters = Schema.object([
        "from": Schema.string("开始日期 YYYY-MM-DD，默认今天"),
        "to": Schema.string("结束日期 YYYY-MM-DD（含），默认与 from 相同"),
        "include_drafts": Schema.boolean("包含未确认草稿"),
    ])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let from = ctx.clock.startOfDay(ctx.clock.parse(args["from"]?.stringValue, relativeTo: ctx.now) ?? ctx.now)
        let toDay = ctx.clock.parse(args["to"]?.stringValue, relativeTo: ctx.now) ?? from
        let to = ctx.clock.endOfDay(max(toDay, from))
        guard to.timeIntervalSince(from) <= 31 * 86_400 else { return .error("一次最多查 31 天") }
        let meals = try ctx.services.meals.meals(from: from, to: to, includeDrafts: args["include_drafts"]?.boolValue ?? false)
        let o: JSONValue = [
            "meals": .array(meals.map { $0.json(clock: ctx.clock) }),
            "total": meals.reduce(Nutrients.zero) { $0 + $1.totals }.json,
        ]
        return ToolResult(o, summary: "查看了 \(meals.count) 条饮食记录")
    }
}

struct SavePersonalFoodTool: AgentTool {
    let name = "save_personal_food"
    let description = "把用户常吃的食物存进个人食物库（如“公司食堂鸡腿饭”“妈妈做的红烧肉”），以后 search_food 会优先返回。可从已有 food_id 复制营养，或直接给 per100g。"
    let parameters = Schema.object([
        "name": Schema.string("名字"),
        "aliases": Schema.string("别名，逗号分隔"),
        "from_food_id": Schema.string("从已有条目复制营养"),
        "per100g": FoodTools.per100gSchema,
        "typical_grams": Schema.number("TA 通常吃多少克"),
        "note": Schema.string("备注"),
    ], required: ["name"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let name = args["name"]?.stringValue, !name.isEmpty else { return .error("缺少 name") }
        var nutrients = Nutrients(json: args["per100g"])
        var sourceRef: String?
        if nutrients == nil, let fid = args["from_food_id"]?.stringValue, let food = await ctx.services.foodSearch.lookup(id: fid) {
            nutrients = food.per100g
            sourceRef = food.id
        }
        guard let nutrients else { return .error("需要 per100g 或有效的 from_food_id") }
        let food = try ctx.services.personalFoods.upsert(
            name: name, per100g: nutrients, aliases: args["aliases"]?.stringValue, note: args["note"]?.stringValue,
            grams: args["typical_grams"]?.doubleValue, sourceRef: sourceRef, now: ctx.now)
        return ToolResult(["ok": true, "food": food.json], summary: "存入个人食物库：\(name)")
    }
}
