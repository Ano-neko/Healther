import Foundation

/// How much to eat per day: what the body burns, adjusted for the weekly weight change the user wants.
/// A fixed `daily_kcal` goal overrides the suggestion; without one the target follows the data.
public struct EnergyPlan: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// Average of Apple Watch basal + active energy over recent full days.
        case watch
        /// Mifflin-St Jeor BMR × an activity factor from recent steps.
        case formula
    }

    /// Estimated daily expenditure (kcal).
    public var burn: Double
    public var source: Source
    /// Watch days averaged (source == .watch).
    public var daysMeasured: Int
    /// Desired change in kg per week; negative = lose, 0 = maintain.
    public var weeklyChangeKg: Double
    /// burn + weekly change, kept within safe limits.
    public var suggested: Double
    /// Lowest daily intake suggested without medical supervision.
    public var floor: Double
    /// True when the requested pace had to be softened.
    public var limited: Bool
    /// A fixed goal set by the user or agreed with the agent.
    public var fixed: Double?
    /// Guesses that went into the estimate ("年龄按 30 岁估算").
    public var assumptions: [String]

    public var target: Double { fixed ?? suggested }

    /// One kilogram of body weight ≈ 7700 kcal.
    static let kcalPerKg = 7700.0

    static func suggest(burn: Double, weeklyChangeKg: Double, sex: BodyProfile.Sex?) -> (kcal: Double, floor: Double, limited: Bool) {
        let floor: Double = sex == .male ? 1500 : sex == .female ? 1200 : 1350
        var delta = weeklyChangeKg * kcalPerKg / 7
        var limited = false
        // Deficit ≤ min(1000, 25% of burn); surplus ≤ 500.
        let maxDeficit = min(1000, burn * 0.25)
        if delta < -maxDeficit { delta = -maxDeficit; limited = true }
        if delta > 500 { delta = 500; limited = true }
        var kcal = burn + delta
        if kcal < floor { kcal = floor; limited = limited || weeklyChangeKg < 0 }
        return ((kcal / 10).rounded() * 10, floor, limited)
    }

    /// For prompts and the settings footer.
    public var explanation: String {
        let how = source == .watch ? "近 \(daysMeasured) 天手表测得平均每天消耗 \(fmt(burn)) kcal" : "按身高体重年龄估算每天消耗约 \(fmt(burn)) kcal"
        let kg = String(format: "%g", (abs(weeklyChangeKg) * 100).rounded() / 100)
        let pace = weeklyChangeKg == 0 ? "维持体重" : (weeklyChangeKg < 0 ? "每周减 \(kg) kg" : "每周增 \(kg) kg")
        var s = "\(how)，\(pace) → 建议每天 \(fmt(suggested)) kcal"
        if limited { s += "（已按安全范围放缓）" }
        if !assumptions.isEmpty { s += "；" + assumptions.joined(separator: "，") }
        return s
    }

    public var json: JSONValue {
        [
            "target_kcal": .rounded(target, 0), "mode": .string(fixed == nil ? "auto" : "fixed"),
            "estimated_burn_kcal": .rounded(burn, 0), "burn_source": .string(source == .watch ? "watch_\(daysMeasured)d" : "formula"),
            "weekly_change_kg": .rounded(weeklyChangeKg, 2), "suggested_kcal": .rounded(suggested, 0),
            "floor_kcal": .rounded(floor, 0), "limited": .bool(limited),
            "assumptions": .array(assumptions.map(JSONValue.string)),
        ]
    }
}

extension HealtherServices {
    /// nil when there is neither enough watch data nor height + weight to estimate from.
    public func energyPlan(now: Date = Date()) async -> EnergyPlan? {
        let fixed = wellbeing.goal(.dailyKcal)?.target
        let change = wellbeing.goal(.weeklyWeightChange)?.target ?? 0
        let body = body.current
        let sex = body.sex.flatMap(BodyProfile.Sex.init(rawValue:))
        var assumptions: [String] = []

        var burn: Double?
        var source = EnergyPlan.Source.formula
        var days = 0
        // Full past days only; a day with little basal energy means the watch was off for part of it.
        let yesterday = clock.addDays(-1, to: now)
        let basal = (try? await dailyValues(.basalEnergy, days: 14, endingAt: yesterday)) ?? []
        let active = (try? await dailyValues(.activeEnergy, days: 14, endingAt: yesterday)) ?? []
        let totals = zip(basal, active).compactMap { b, a -> Double? in
            guard let b = b.value, b >= 900 else { return nil }
            return b + (a.value ?? 0)
        }
        if totals.count >= 4 {
            let avg = totals.reduce(0, +) / Double(totals.count)
            if (1000...6000).contains(avg) {
                burn = avg
                source = .watch
                days = totals.count
            }
        }

        if burn == nil {
            guard let weight = try? await healthSummary(for: now).bodyMass, let height = body.heightCm else { return nil }
            var age = body.age(now: now, calendar: clock.calendar) ?? 0
            if age <= 0 {
                age = 30
                assumptions.append("年龄按 30 岁估算")
            }
            let sexTerm: Double
            switch sex {
            case .male: sexTerm = 5
            case .female: sexTerm = -161
            case nil: sexTerm = -78; assumptions.append("没填性别，取男女平均")
            }
            let bmr = 10 * weight + 6.25 * height - 5 * Double(age) + sexTerm
            let steps = ((try? await dailyValues(.steps, days: 7, endingAt: yesterday)) ?? []).compactMap(\.value)
            let factor: Double
            if steps.count >= 3 {
                let avg = steps.reduce(0, +) / Double(steps.count)
                factor = avg < 4000 ? 1.3 : avg < 8000 ? 1.45 : avg < 12000 ? 1.6 : 1.75
            } else {
                factor = 1.4
                assumptions.append("活动量按中等估算")
            }
            burn = bmr * factor
        }

        guard let burn else { return nil }
        let s = EnergyPlan.suggest(burn: burn, weeklyChangeKg: change, sex: sex)
        return EnergyPlan(burn: burn, source: source, daysMeasured: days, weeklyChangeKg: change, suggested: s.kcal,
                          floor: s.floor, limited: s.limited, fixed: fixed, assumptions: assumptions)
    }
}
