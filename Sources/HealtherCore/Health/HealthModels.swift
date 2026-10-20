import Foundation

public enum HealthMetric: String, Codable, Sendable, CaseIterable {
    case steps
    case activeEnergy = "active_energy"
    case exerciseMinutes = "exercise_minutes"
    case standHours = "stand_hours"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "hrv"
    case respiratoryRate = "respiratory_rate"
    case vo2Max = "vo2max"
    case bodyMass = "weight"
    case bodyFat = "body_fat"
    case sleepHours = "sleep_hours"
    case mindfulMinutes = "mindful_minutes"
    case dietaryEnergy = "dietary_energy"
    case water

    public enum Aggregation: Sendable { case sum, average, latest }

    public var aggregation: Aggregation {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .standHours, .mindfulMinutes, .dietaryEnergy, .water, .sleepHours: return .sum
        case .restingHeartRate, .heartRateVariability, .respiratoryRate: return .average
        case .vo2Max, .bodyMass, .bodyFat: return .latest
        }
    }

    public var unit: String {
        switch self {
        case .steps: return "步"
        case .activeEnergy, .dietaryEnergy: return "kcal"
        case .exerciseMinutes, .mindfulMinutes: return "分钟"
        case .standHours: return "小时"
        case .restingHeartRate: return "bpm"
        case .heartRateVariability: return "ms"
        case .respiratoryRate: return "次/分"
        case .vo2Max: return "ml/kg/min"
        case .bodyMass: return "kg"
        case .bodyFat: return "%"
        case .sleepHours: return "小时"
        case .water: return "ml"
        }
    }

    public var displayName: String {
        switch self {
        case .steps: return "步数"
        case .activeEnergy: return "活动能量"
        case .exerciseMinutes: return "锻炼时间"
        case .standHours: return "站立小时"
        case .restingHeartRate: return "静息心率"
        case .heartRateVariability: return "心率变异性(HRV)"
        case .respiratoryRate: return "呼吸频率"
        case .vo2Max: return "最大摄氧量"
        case .bodyMass: return "体重"
        case .bodyFat: return "体脂率"
        case .sleepHours: return "睡眠时长"
        case .mindfulMinutes: return "正念时间"
        case .dietaryEnergy: return "膳食能量"
        case .water: return "饮水"
        }
    }
}

public struct SleepSummary: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var asleepHours: Double
    public var deepHours: Double?
    public var remHours: Double?
    public var coreHours: Double?
    public var awakeHours: Double?

    public init(start: Date, end: Date, asleepHours: Double, deepHours: Double? = nil, remHours: Double? = nil,
                coreHours: Double? = nil, awakeHours: Double? = nil) {
        self.start = start
        self.end = end
        self.asleepHours = asleepHours
        self.deepHours = deepHours
        self.remHours = remHours
        self.coreHours = coreHours
        self.awakeHours = awakeHours
    }

    public func json(clock: DayClock) -> JSONValue {
        [
            "bedtime": .string(clock.stamp(start)), "wake": .string(clock.stamp(end)),
            "asleep_h": .rounded(asleepHours), "deep_h": .rounded(deepHours), "rem_h": .rounded(remHours),
            "core_h": .rounded(coreHours), "awake_h": .rounded(awakeHours),
        ]
    }
}

public struct Workout: Codable, Sendable, Hashable {
    public var type: String
    public var start: Date
    public var minutes: Double
    public var kcal: Double?
    public var distanceKm: Double?
    public var avgHeartRate: Double?

    public init(type: String, start: Date, minutes: Double, kcal: Double? = nil, distanceKm: Double? = nil, avgHeartRate: Double? = nil) {
        self.type = type
        self.start = start
        self.minutes = minutes
        self.kcal = kcal
        self.distanceKm = distanceKm
        self.avgHeartRate = avgHeartRate
    }

    public func json(clock: DayClock) -> JSONValue {
        [
            "type": .string(type), "start": .string(clock.timeString(start)), "minutes": .rounded(minutes, 0),
            "kcal": .rounded(kcal, 0), "distance_km": .rounded(distanceKm, 2), "avg_hr": .rounded(avgHeartRate, 0),
        ]
    }
}

/// One local day of Apple Health data. Nil = no data recorded.
public struct DailyHealthSummary: Codable, Sendable, Hashable {
    public var day: String
    public var steps: Double?
    public var activeEnergy: Double?
    public var exerciseMinutes: Double?
    public var standHours: Double?
    public var restingHeartRate: Double?
    public var hrv: Double?
    public var respiratoryRate: Double?
    public var mindfulMinutes: Double?
    /// The sleep session that ended on this day's morning.
    public var sleep: SleepSummary?
    /// Most recent weight on or before this day.
    public var bodyMass: Double?
    public var bodyMassDate: Date?
    public var bodyFat: Double?
    public var workouts: [Workout]

    public init(day: String) {
        self.day = day
        workouts = []
    }

    public func json(clock: DayClock) -> JSONValue {
        var o: [String: JSONValue] = [
            "day": .string(day), "steps": .rounded(steps, 0), "active_kcal": .rounded(activeEnergy, 0),
            "exercise_min": .rounded(exerciseMinutes, 0), "stand_h": .rounded(standHours, 0),
            "resting_hr": .rounded(restingHeartRate, 0), "hrv_ms": .rounded(hrv, 0),
            "weight_kg": .rounded(bodyMass), "body_fat_pct": .rounded(bodyFat),
        ]
        if let respiratoryRate { o["resp_rate"] = .rounded(respiratoryRate) }
        if let mindfulMinutes, mindfulMinutes > 0 { o["mindful_min"] = .rounded(mindfulMinutes, 0) }
        if let bodyMassDate { o["weight_date"] = .string(clock.dayKey(bodyMassDate)) }
        o["sleep"] = sleep?.json(clock: clock) ?? .null
        if !workouts.isEmpty { o["workouts"] = .array(workouts.map { $0.json(clock: clock) }) }
        return .object(o.filter { !$0.value.isNull })
    }
}

public struct DailyValue: Codable, Sendable, Hashable {
    public var day: Date
    public var value: Double?
    public init(day: Date, value: Double?) {
        self.day = day
        self.value = value
    }
}

public enum BodyMeasurement: Sendable, Hashable {
    case weight(kg: Double)
    case bodyFat(percent: Double)
    case bloodPressure(systolic: Double, diastolic: Double)
    case restingHeartRate(bpm: Double)
}

public struct MoodEntry: Codable, Sendable, Hashable {
    public var at: Date
    /// -3 (very unpleasant) ... +3 (very pleasant), mapped to HealthKit State of Mind valence.
    public var valence: Int
    public var labels: [String]
    public var note: String?

    public init(at: Date, valence: Int, labels: [String], note: String?) {
        self.at = at
        self.valence = max(-3, min(3, valence))
        self.labels = labels
        self.note = note
    }
}
