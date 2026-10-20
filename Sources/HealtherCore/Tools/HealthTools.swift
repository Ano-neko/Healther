import Foundation

enum HealthTools {
    static let all: [any AgentTool] = [HealthOverviewTool(), HealthTrendTool()]
}

struct HealthOverviewTool: AgentTool {
    let name = "get_health_overview"
    let description = "查询某一天的完整状况：Apple Watch 数据（睡眠、步数、活动、心率、HRV、体重、运动记录）、饮食合计与各餐、饮水、情绪记录、目标。默认今天。"
    let parameters = Schema.object([
        "date": Schema.string("YYYY-MM-DD，默认今天。睡眠指的是这天早上醒来的那一觉。"),
    ])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let s = ctx.services
        let day = ctx.clock.parse(args["date"]?.stringValue, relativeTo: ctx.now) ?? ctx.now
        let start = ctx.clock.startOfDay(day), end = ctx.clock.endOfDay(day)
        let health = try await s.health.dailySummary(for: day)
        let meals = try s.meals.meals(from: start, to: end)
        var o: [String: JSONValue] = [
            "date": .string(ctx.clock.dayKey(day)),
            "weekday": .string(ctx.clock.weekdayName(day)),
            "health": health.json(clock: ctx.clock),
            "nutrition_total": try s.meals.totals(from: start, to: end).json,
            "meals": .array(meals.map { $0.json(clock: ctx.clock) }),
            "water_ml": .rounded(try s.wellbeing.water(from: start, to: end), 0),
            "moods": .array(try s.wellbeing.moods(from: start, to: end).map {
                ["time": .string(ctx.clock.timeString($0.at)), "valence": .number(Double($0.valence)),
                 "labels": .array($0.labels.map(JSONValue.string)), "note": JSONValue($0.note)]
            }),
            "goals": .object(Dictionary(uniqueKeysWithValues: try s.wellbeing.goals().map { ($0.kind.rawValue, JSONValue.number($0.target)) })),
        ]
        if s.health.isMock { o["note"] = "开发环境：健康数据为模拟数据" }
        return ToolResult(.object(o), summary: "查看了 \(ctx.clock.dayKey(day)) 的概况")
    }
}

struct HealthTrendTool: AgentTool {
    let name = "query_health_trend"
    let description = "查询某项指标最近 N 天的每日数值和统计（平均/最小/最大），用来看趋势、做对比。"
    let parameters = Schema.object([
        "metric": Schema.string("指标", enum: HealthMetric.allCases.map(\.rawValue)),
        "days": Schema.integer("天数（含今天），1–90，默认 14", minimum: 1, maximum: 90),
        "end_date": Schema.string("截止日期 YYYY-MM-DD，默认今天"),
    ], required: ["metric"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let metric = HealthMetric(rawValue: args["metric"]?.stringValue ?? "") else { return .error("未知指标") }
        let days = max(1, min(90, args["days"]?.intValue ?? 14))
        let end = ctx.clock.parse(args["end_date"]?.stringValue, relativeTo: ctx.now) ?? ctx.now
        let s = ctx.services
        var values: [DailyValue]
        switch metric {
        case .dietaryEnergy:
            values = try (0..<days).reversed().map { back in
                let d = ctx.clock.startOfDay(ctx.clock.addDays(-back, to: end))
                let k = try s.meals.totals(from: d, to: ctx.clock.endOfDay(d)).kcal
                return DailyValue(day: d, value: k > 0 ? k : nil)
            }
        case .water:
            values = try (0..<days).reversed().map { back in
                let d = ctx.clock.startOfDay(ctx.clock.addDays(-back, to: end))
                let w = try s.wellbeing.water(from: d, to: ctx.clock.endOfDay(d))
                return DailyValue(day: d, value: w > 0 ? w : nil)
            }
        default:
            values = try await s.health.dailyValues(metric, days: days, endingAt: end)
        }
        let present = values.compactMap(\.value)
        let places = [.bodyMass, .bodyFat, .sleepHours, .vo2Max, .respiratoryRate].contains(metric) ? 1 : 0
        var stats: [String: JSONValue] = ["days_with_data": .number(Double(present.count))]
        if !present.isEmpty {
            stats["avg"] = .rounded(present.reduce(0, +) / Double(present.count), places)
            stats["min"] = .rounded(present.min(), places)
            stats["max"] = .rounded(present.max(), places)
            stats["latest"] = .rounded(present.last, places)
        }
        let o: JSONValue = [
            "metric": .string(metric.rawValue), "name": .string(metric.displayName), "unit": .string(metric.unit),
            "daily": .array(values.map { [.string(String(ctx.clock.dayKey($0.day).suffix(5))), .rounded($0.value, places)] }),
            "stats": .object(stats),
        ]
        return ToolResult(o, summary: "查看了 \(days) 天的\(metric.displayName)")
    }
}
