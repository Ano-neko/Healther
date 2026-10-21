import Foundation

enum WellbeingTools {
    static let all: [any AgentTool] = [LogBodyTool(), UpdateBodyProfileTool(), LogWaterTool(), LogMoodTool(), SetGoalTool(), SetTodayCardTool()]
}

struct SetTodayCardTool: AgentTool {
    let name = "set_today_card"
    let description = "设置 App「今日」页顶部的标题和一段话，替代默认的自动文案。和 TA 商量出当天的重点、计划或提醒后用它钉上去，也可以是一句诗、一句标语；也可以提前写好明天的。正文最多显示三行，超出的部分 TA 点开才能看到。title 为空字符串则清除，恢复默认。"
    let parameters = Schema.object([
        "title": Schema.string("标题，简短，如“今天悠着点”“练腿日”“冬灯 · 静种”"),
        "detail": Schema.string("正文，最好三行以内（约 60 个汉字或 120 个英文字母），如“昨晚只睡 5 小时，午后别喝咖啡，11 点前睡”"),
        "font": Schema.string("字体，按内容气质挑：" + CardFont.allCases.map(\.hint).joined(separator: "；") + "。不传则沿用这一天原来的字体",
                              enum: CardFont.allCases.map(\.rawValue)),
        "day": Schema.string("日期 YYYY-MM-DD，默认今天"),
    ], required: ["title"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let day = args["day"]?.stringValue.flatMap { ctx.clock.date(fromDayKey: $0) } ?? ctx.now
        let key = ctx.clock.dayKey(day)
        let title = (args["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            try ctx.services.dayNotes.set(nil, for: key)
            return ToolResult(["ok": true, "day": .string(key), "cleared": true], summary: "清除了 \(key) 的今日卡片")
        }
        let detail = (args["detail"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count <= DayNote.maxTitle, detail.count <= DayNote.maxDetail else {
            return .error("太长了：标题最多 \(DayNote.maxTitle) 字，正文最多 \(DayNote.maxDetail) 字。精简后再钉")
        }
        let font = args["font"]?.stringValue.flatMap(CardFont.init(rawValue:))?.rawValue ?? ctx.services.dayNotes.note(for: key)?.font
        try ctx.services.dayNotes.set(DayNote(title: title, detail: detail, updatedAt: ctx.now, font: font), for: key)
        return ToolResult(["ok": true, "day": .string(key), "title": .string(title), "font": JSONValue(font)], summary: "今日卡片：\(title)")
    }
}

struct LogBodyTool: AgentTool {
    let name = "log_body_measurement"
    let description = "记录用户报告的身体数据，写入 Apple 健康：体重、体脂率、血压。"
    let parameters = Schema.object([
        "kind": Schema.string("类型", enum: ["weight", "body_fat", "blood_pressure"]),
        "value": Schema.number("体重 kg / 体脂 % / 收缩压 mmHg"),
        "value2": Schema.number("舒张压 mmHg（仅血压）"),
        "at": Schema.string("测量时间，默认现在"),
    ], required: ["kind", "value"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let v = args["value"]?.doubleValue else { return .error("缺少 value") }
        let at = ctx.clock.parse(args["at"]?.stringValue, relativeTo: ctx.now) ?? ctx.now
        let m: BodyMeasurement
        let label: String
        switch args["kind"]?.stringValue {
        case "weight":
            guard (20...300).contains(v) else { return .error("体重数值不合理") }
            m = .weight(kg: v); label = "体重 \(fmt(v, 1))kg"
        case "body_fat":
            guard (2...70).contains(v) else { return .error("体脂数值不合理") }
            m = .bodyFat(percent: v); label = "体脂 \(fmt(v, 1))%"
        case "blood_pressure":
            guard let d = args["value2"]?.doubleValue, (60...260).contains(v), (30...160).contains(d) else { return .error("血压需要合理的收缩压和舒张压") }
            m = .bloodPressure(systolic: v, diastolic: d); label = "血压 \(fmt(v))/\(fmt(d))"
        default:
            return .error("未知 kind")
        }
        if case .weight(let kg) = m {
            // Kept locally too, so it counts even when Apple Health won't take it.
            try ctx.services.body.addWeight(kg: kg, at: at)
            try? await ctx.services.health.save(m, at: at)
        } else {
            try await ctx.services.health.save(m, at: at)
        }
        return ToolResult(["ok": true, "saved": .string(label)], summary: "记录了\(label)")
    }
}

struct UpdateBodyProfileTool: AgentTool {
    let name = "update_body_profile"
    let description = "更新 TA 的身体资料：身高、出生年份、性别（App 设置里「我的身体」也显示和修改这些）。只传要改的字段；TA 说了才记，不要猜。"
    let parameters = Schema.object([
        "height_cm": Schema.number("身高 cm"),
        "birth_year": Schema.integer("出生年份，如 1998；TA 只说了年龄就用今年减去年龄", minimum: 1900, maximum: 2030),
        "sex": Schema.string("性别", enum: BodyProfile.Sex.allCases.map(\.rawValue)),
    ])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        var p = ctx.services.body.manual
        var changed: [String] = []
        if let h = args["height_cm"]?.doubleValue {
            guard (80...250).contains(h) else { return .error("身高数值不合理") }
            p.heightCm = h; changed.append("身高 \(fmt(h))cm")
        }
        if let y = args["birth_year"]?.intValue {
            let year = ctx.clock.calendar.component(.year, from: ctx.now)
            guard (year - 120...year - 3).contains(y) else { return .error("出生年份不合理") }
            p.birthYear = y; changed.append("出生 \(y) 年")
        }
        if let raw = args["sex"]?.stringValue {
            guard let sex = BodyProfile.Sex(rawValue: raw) else { return .error("未知性别值") }
            p.sex = sex.rawValue; changed.append("性别 \(sex.title)")
        }
        guard !changed.isEmpty else { return .error("没有要更新的字段") }
        try ctx.services.body.setManual(p)
        let label = changed.joined(separator: "，")
        return ToolResult(["ok": true], summary: "身体资料：\(label)", events: [.memoryChanged("身体资料：\(label)")])
    }
}

struct LogWaterTool: AgentTool {
    let name = "log_water"
    let description = "记录喝水（一杯约 250ml，一瓶矿泉水约 550ml）。"
    let parameters = Schema.object([
        "ml": Schema.number("毫升"),
        "at": Schema.string("时间，默认现在"),
    ], required: ["ml"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let ml = args["ml"]?.doubleValue, ml > 0, ml < 5000 else { return .error("ml 不合理") }
        let at = ctx.clock.parse(args["at"]?.stringValue, relativeTo: ctx.now) ?? ctx.now
        try ctx.services.wellbeing.addWater(ml: ml, at: at)
        try? await ctx.services.health.saveWater(ml: ml, at: at)
        let total = try ctx.services.wellbeing.water(from: ctx.clock.startOfDay(at), to: ctx.clock.endOfDay(at))
        return ToolResult(["ok": true, "today_total_ml": .rounded(total, 0), "goal_ml": JSONValue(ctx.services.wellbeing.goal(.waterML)?.target)],
                          summary: "喝水 +\(fmt(ml))ml")
    }
}

struct LogMoodTool: AgentTool {
    let name = "log_mood"
    let description = "记录用户此刻的情绪（写入 Apple 健康的“心理状态”）。在 TA 明显流露情绪时使用。"
    let parameters = Schema.object([
        "valence": Schema.integer("-3 非常不愉快 … 0 中性 … +3 非常愉快", minimum: -3, maximum: 3),
        "labels": Schema.array(Schema.string("情绪词，英文：happy, calm, content, grateful, excited, hopeful, proud, relieved, anxious, worried, stressed, overwhelmed, sad, lonely, drained, frustrated, disappointed, irritated, angry, scared, guilty, indifferent"), "1–3 个"),
        "note": Schema.string("一句话原因，如“项目上线压力大”"),
    ], required: ["valence"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let entry = MoodEntry(at: ctx.now, valence: args["valence"]?.intValue ?? 0,
                              labels: args["labels"]?.arrayValue?.compactMap(\.stringValue) ?? [], note: args["note"]?.stringValue)
        try ctx.services.wellbeing.addMood(entry)
        try? await ctx.services.health.save(mood: entry)
        return ToolResult(["ok": true], summary: "记下了情绪 \(entry.valence > 0 ? "+" : "")\(entry.valence) \(entry.labels.joined(separator: "/"))")
    }
}

struct SetGoalTool: AgentTool {
    let name = "set_goal"
    let description = "设置或清除一个数字目标（和用户商量好之后再设）。每日热量默认自动计算（消耗 + weekly_weight_change），一般只设 weekly_weight_change；TA 坚持要固定数字才设 daily_kcal，清除 daily_kcal 即回到自动。"
    let parameters = Schema.object([
        "kind": Schema.string(WellbeingStore.GoalKind.allCases.map { "\($0.rawValue)=\($0.title)（\($0.unit)）" }.joined(separator: "；"),
                              enum: WellbeingStore.GoalKind.allCases.map(\.rawValue)),
        "target": Schema.nullable(Schema.number("目标值；入睡时间用 24h 小数（23.5=23:30）；每周体重变化减重填负数（-0.5 = 每周减 0.5kg）；null 表示清除")),
        "note": Schema.string("说明，如“减脂期，每周 -0.5kg”"),
    ], required: ["kind", "target"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let kind = WellbeingStore.GoalKind(rawValue: args["kind"]?.stringValue ?? "") else { return .error("未知目标类型") }
        let target = args["target"]?.doubleValue
        try ctx.services.wellbeing.setGoal(kind, target: target, note: args["note"]?.stringValue, now: ctx.now)
        let places = kind == .weeklyWeightChange ? 2 : kind == .weightKg || kind == .sleepHours ? 1 : 0
        let label = target.map { "\(kind.title) → \(fmt($0, places))\(kind.unit)" } ?? "清除了\(kind.title)目标"
        var o: [String: JSONValue] = ["ok": true]
        if kind == .dailyKcal || kind == .weeklyWeightChange, let plan = await ctx.services.energyPlan(now: ctx.now) {
            o["energy_plan"] = plan.json
        }
        return ToolResult(.object(o), summary: label, events: [.memoryChanged("目标：\(label)")])
    }
}
