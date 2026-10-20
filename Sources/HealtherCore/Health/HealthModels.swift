import Foundation

/// Raw values are stored (tool calls, mock samples): add cases freely, never rename.
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

    // Everything else Apple Health can hold that matters for a companion.
    case basalEnergy = "basal_energy"
    case heartRate = "heart_rate"
    case walkingHeartRate = "walking_heart_rate"
    case heartRateRecovery = "hr_recovery"
    case bloodOxygen = "blood_oxygen"
    case wristTemperature = "wrist_temperature"
    case breathingDisturbances = "breathing_disturbances"
    case standMinutes = "stand_minutes"
    case distanceWalkingRunning = "distance_walk_run"
    case distanceCycling = "distance_cycling"
    case distanceSwimming = "distance_swimming"
    case flightsClimbed = "flights_climbed"
    case daylightMinutes = "daylight_minutes"
    case walkingSpeed = "walking_speed"
    case walkingStepLength = "step_length"
    case walkingAsymmetry = "walking_asymmetry"
    case walkingSteadiness = "walking_steadiness"
    case height
    case bmi
    case leanBodyMass = "lean_body_mass"
    case waist
    case bloodPressureSystolic = "bp_systolic"
    case bloodPressureDiastolic = "bp_diastolic"
    case bloodGlucose = "blood_glucose"
    case environmentalNoise = "env_noise"
    case headphoneAudio = "headphone_audio"
    case caffeine
    case afibBurden = "afib_burden"

    public enum Aggregation: Sendable { case sum, average, latest }

    /// Fields of `DailyHealthSummary`; everything else goes into `extra`.
    public static let core: Set<HealthMetric> = [
        .steps, .activeEnergy, .exerciseMinutes, .standHours, .restingHeartRate, .heartRateVariability,
        .respiratoryRate, .bodyMass, .bodyFat, .sleepHours, .mindfulMinutes, .dietaryEnergy, .water,
    ]

    public static var extras: [HealthMetric] { allCases.filter { !core.contains($0) } }

    public var aggregation: Aggregation {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .standHours, .mindfulMinutes, .dietaryEnergy, .water, .sleepHours,
             .basalEnergy, .standMinutes, .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .flightsClimbed,
             .daylightMinutes, .caffeine:
            return .sum
        case .restingHeartRate, .heartRateVariability, .respiratoryRate, .heartRate, .walkingHeartRate, .heartRateRecovery,
             .bloodOxygen, .wristTemperature, .breathingDisturbances, .walkingSpeed, .walkingStepLength, .walkingAsymmetry,
             .bloodPressureSystolic, .bloodPressureDiastolic, .bloodGlucose, .environmentalNoise, .headphoneAudio:
            return .average
        case .vo2Max, .bodyMass, .bodyFat, .walkingSteadiness, .height, .bmi, .leanBodyMass, .waist, .afibBurden:
            return .latest
        }
    }

    /// Decimal places worth showing.
    public var places: Int {
        switch self {
        case .bodyMass, .bodyFat, .sleepHours, .vo2Max, .respiratoryRate, .bloodOxygen, .wristTemperature, .breathingDisturbances,
             .distanceWalkingRunning, .distanceCycling, .walkingSpeed, .walkingAsymmetry, .bmi, .leanBodyMass, .bloodGlucose:
            return 1
        default:
            return 0
        }
    }

    public var unit: String {
        switch self {
        case .steps: return "步"
        case .activeEnergy, .dietaryEnergy, .basalEnergy: return "kcal"
        case .exerciseMinutes, .mindfulMinutes, .standMinutes, .daylightMinutes: return "分钟"
        case .standHours: return "小时"
        case .restingHeartRate, .heartRate, .walkingHeartRate, .heartRateRecovery: return "bpm"
        case .heartRateVariability: return "ms"
        case .respiratoryRate: return "次/分"
        case .vo2Max: return "ml/kg/min"
        case .bodyMass, .leanBodyMass: return "kg"
        case .bodyFat, .bloodOxygen, .walkingAsymmetry, .walkingSteadiness, .afibBurden: return "%"
        case .sleepHours: return "小时"
        case .water: return "ml"
        case .wristTemperature: return "℃"
        case .breathingDisturbances: return "次/小时"
        case .distanceWalkingRunning, .distanceCycling: return "km"
        case .distanceSwimming: return "m"
        case .flightsClimbed: return "层"
        case .walkingSpeed: return "km/h"
        case .walkingStepLength, .height, .waist: return "cm"
        case .bmi: return ""
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "mmHg"
        case .bloodGlucose: return "mmol/L"
        case .environmentalNoise, .headphoneAudio: return "dB"
        case .caffeine: return "mg"
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
        case .basalEnergy: return "静息能量"
        case .heartRate: return "平均心率"
        case .walkingHeartRate: return "步行平均心率"
        case .heartRateRecovery: return "心率恢复(1分钟)"
        case .bloodOxygen: return "血氧"
        case .wristTemperature: return "睡眠腕温"
        case .breathingDisturbances: return "睡眠呼吸紊乱"
        case .standMinutes: return "站立时间"
        case .distanceWalkingRunning: return "步行+跑步距离"
        case .distanceCycling: return "骑行距离"
        case .distanceSwimming: return "游泳距离"
        case .flightsClimbed: return "已爬楼层"
        case .daylightMinutes: return "日光下时间"
        case .walkingSpeed: return "步行速度"
        case .walkingStepLength: return "步长"
        case .walkingAsymmetry: return "步行不对称性"
        case .walkingSteadiness: return "步行稳定性"
        case .height: return "身高"
        case .bmi: return "BMI"
        case .leanBodyMass: return "去脂体重"
        case .waist: return "腰围"
        case .bloodPressureSystolic: return "收缩压"
        case .bloodPressureDiastolic: return "舒张压"
        case .bloodGlucose: return "血糖"
        case .environmentalNoise: return "环境音量"
        case .headphoneAudio: return "耳机音量"
        case .caffeine: return "咖啡因"
        case .afibBurden: return "房颤负荷"
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
    /// Any other metric with data that day (latest-style ones may come from earlier days).
    public var extra: [HealthMetric: Double]
    /// Notable one-off records: heart-rate alerts, period, … ("14:32 高心率提醒").
    public var events: [String]

    public init(day: String) {
        self.day = day
        workouts = []
        extra = [:]
        events = []
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
        for (m, v) in extra { o[m.rawValue] = .rounded(v, m.places) }
        if !events.isEmpty { o["events"] = .array(events.map(JSONValue.string)) }
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
