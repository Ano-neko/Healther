import Foundation

enum WellbeingTools {
    static let all: [any AgentTool] = [LogBodyTool(), LogWaterTool(), LogMoodTool(), SetGoalTool()]
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
        try await ctx.services.health.save(m, at: at)
        return ToolResult(["ok": true, "saved": .string(label)], summary: "记录了\(label)")
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
    let description = "设置或清除一个数字目标（和用户商量好之后再设）。"
    let parameters = Schema.object([
        "kind": Schema.string("目标类型", enum: WellbeingStore.GoalKind.allCases.map(\.rawValue)),
        "target": Schema.nullable(Schema.number("目标值；入睡时间用 24h 小数（23.5=23:30）；null 表示清除")),
        "note": Schema.string("说明，如“减脂期，每周 -0.5kg”"),
    ], required: ["kind", "target"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let kind = WellbeingStore.GoalKind(rawValue: args["kind"]?.stringValue ?? "") else { return .error("未知目标类型") }
        let target = args["target"]?.doubleValue
        try ctx.services.wellbeing.setGoal(kind, target: target, note: args["note"]?.stringValue, now: ctx.now)
        let label = target.map { "\(kind.title) → \(fmt($0, kind == .weightKg || kind == .sleepHours ? 1 : 0))\(kind.unit)" } ?? "清除了\(kind.title)目标"
        return ToolResult(["ok": true], summary: label, events: [.memoryChanged("目标：\(label)")])
    }
}
