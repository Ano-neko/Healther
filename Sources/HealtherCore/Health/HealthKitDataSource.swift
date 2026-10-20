#if canImport(HealthKit)
import Foundation
import HealthKit

/// Apple Health backed implementation. Compiled only on Apple platforms.
public final class HealthKitDataSource: HealthDataSource, @unchecked Sendable {
    let store = HKHealthStore()
    let clock: DayClock
    public var isMock: Bool { false }

    static let mealIDKey = "HealtherMealID"

    public init(clock: DayClock = DayClock()) {
        self.clock = clock
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Types

    static func quantityType(_ m: HealthMetric) -> HKQuantityType? {
        switch m {
        case .steps: return HKQuantityType(.stepCount)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .exerciseMinutes: return HKQuantityType(.appleExerciseTime)
        case .restingHeartRate: return HKQuantityType(.restingHeartRate)
        case .heartRateVariability: return HKQuantityType(.heartRateVariabilitySDNN)
        case .respiratoryRate: return HKQuantityType(.respiratoryRate)
        case .vo2Max: return HKQuantityType(.vo2Max)
        case .bodyMass: return HKQuantityType(.bodyMass)
        case .bodyFat: return HKQuantityType(.bodyFatPercentage)
        case .dietaryEnergy: return HKQuantityType(.dietaryEnergyConsumed)
        case .water: return HKQuantityType(.dietaryWater)
        case .basalEnergy: return HKQuantityType(.basalEnergyBurned)
        case .heartRate: return HKQuantityType(.heartRate)
        case .walkingHeartRate: return HKQuantityType(.walkingHeartRateAverage)
        case .heartRateRecovery: return HKQuantityType(.heartRateRecoveryOneMinute)
        case .bloodOxygen: return HKQuantityType(.oxygenSaturation)
        case .wristTemperature: return HKQuantityType(.appleSleepingWristTemperature)
        case .breathingDisturbances: return HKQuantityType(.appleSleepingBreathingDisturbances)
        case .standMinutes: return HKQuantityType(.appleStandTime)
        case .distanceWalkingRunning: return HKQuantityType(.distanceWalkingRunning)
        case .distanceCycling: return HKQuantityType(.distanceCycling)
        case .distanceSwimming: return HKQuantityType(.distanceSwimming)
        case .flightsClimbed: return HKQuantityType(.flightsClimbed)
        case .daylightMinutes: return HKQuantityType(.timeInDaylight)
        case .walkingSpeed: return HKQuantityType(.walkingSpeed)
        case .walkingStepLength: return HKQuantityType(.walkingStepLength)
        case .walkingAsymmetry: return HKQuantityType(.walkingAsymmetryPercentage)
        case .walkingSteadiness: return HKQuantityType(.appleWalkingSteadiness)
        case .height: return HKQuantityType(.height)
        case .bmi: return HKQuantityType(.bodyMassIndex)
        case .leanBodyMass: return HKQuantityType(.leanBodyMass)
        case .waist: return HKQuantityType(.waistCircumference)
        case .bloodPressureSystolic: return HKQuantityType(.bloodPressureSystolic)
        case .bloodPressureDiastolic: return HKQuantityType(.bloodPressureDiastolic)
        case .bloodGlucose: return HKQuantityType(.bloodGlucose)
        case .environmentalNoise: return HKQuantityType(.environmentalAudioExposure)
        case .headphoneAudio: return HKQuantityType(.headphoneAudioExposure)
        case .caffeine: return HKQuantityType(.dietaryCaffeine)
        case .afibBurden: return HKQuantityType(.atrialFibrillationBurden)
        case .standHours, .sleepHours, .mindfulMinutes: return nil
        }
    }

    static func unit(_ m: HealthMetric) -> HKUnit {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        switch m {
        case .steps, .flightsClimbed, .bmi: return .count()
        case .activeEnergy, .dietaryEnergy, .basalEnergy: return .kilocalorie()
        case .exerciseMinutes, .mindfulMinutes, .standMinutes, .daylightMinutes: return .minute()
        case .restingHeartRate, .respiratoryRate, .heartRate, .walkingHeartRate, .heartRateRecovery: return bpm
        case .heartRateVariability: return .secondUnit(with: .milli)
        case .vo2Max: return HKUnit(from: "ml/kg*min")
        case .bodyMass, .leanBodyMass: return .gramUnit(with: .kilo)
        case .bodyFat, .bloodOxygen, .walkingAsymmetry, .walkingSteadiness, .afibBurden: return .percent()
        case .water: return .literUnit(with: .milli)
        case .standHours, .sleepHours: return .hour()
        case .wristTemperature: return .degreeCelsius()
        case .breathingDisturbances: return .count()
        case .distanceWalkingRunning, .distanceCycling: return .meterUnit(with: .kilo)
        case .distanceSwimming: return .meter()
        case .walkingSpeed: return HKUnit(from: "km/hr")
        case .walkingStepLength, .height, .waist: return .meterUnit(with: .centi)
        case .bloodPressureSystolic, .bloodPressureDiastolic: return .millimeterOfMercury()
        case .bloodGlucose: return HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
        case .environmentalNoise, .headphoneAudio: return .decibelAWeightedSoundPressureLevel()
        case .caffeine: return .gramUnit(with: .milli)
        }
    }

    /// HealthKit stores percentages as 0–1.
    static func scale(_ m: HealthMetric) -> Double {
        unit(m) == .percent() ? 100 : 1
    }

    /// One-off records worth mentioning, with how to describe them.
    static let eventTypes: [(HKCategoryTypeIdentifier, String)] = [
        (.highHeartRateEvent, "高心率提醒"), (.lowHeartRateEvent, "低心率提醒"),
        (.irregularHeartRhythmEvent, "心律不齐提醒"), (.sleepApneaEvent, "睡眠呼吸暂停提醒"),
        (.lowCardioFitnessEvent, "心肺适能偏低提醒"), (.environmentalAudioExposureEvent, "环境噪音过大提醒"),
        (.headphoneAudioExposureEvent, "耳机音量过大提醒"), (.menstrualFlow, "经期"),
    ]

    static var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [
            HKCategoryType(.sleepAnalysis), HKCategoryType(.appleStandHour), HKCategoryType(.mindfulSession),
            HKObjectType.workoutType(), HKQuantityType(.dietaryProtein), HKQuantityType(.dietaryFatTotal),
            HKQuantityType(.dietaryCarbohydrates), HKSampleType.stateOfMindType(),
            HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex),
        ]
        for m in HealthMetric.allCases { if let t = quantityType(m) { s.insert(t) } }
        for (id, _) in eventTypes { s.insert(HKCategoryType(id)) }
        return s
    }

    static var shareTypes: Set<HKSampleType> {
        [
            HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic),
            HKQuantityType(.dietaryEnergyConsumed), HKQuantityType(.dietaryProtein),
            HKQuantityType(.dietaryFatTotal), HKQuantityType(.dietaryCarbohydrates), HKQuantityType(.dietaryWater),
            HKSampleType.stateOfMindType(),
        ]
    }

    /// Calls `onChange` whenever new sleep samples land (the watch syncs them shortly after you wake up),
    /// including when the app is in the background or not running.
    public func observeSleep(_ onChange: @escaping @Sendable () async -> Void) {
        let type = HKCategoryType(.sleepAnalysis)
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            let done = CompletionBox(completion)
            guard error == nil else { done.call(); return }
            Task {
                await onChange()
                done.call()
            }
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    /// HealthKit's completion handler isn't Sendable; it is safe to call from any thread.
    private final class CompletionBox: @unchecked Sendable {
        let f: HKObserverQueryCompletionHandler
        init(_ f: @escaping HKObserverQueryCompletionHandler) { self.f = f }
        func call() { f() }
    }

    public func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthDataError.unavailable }
        try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
    }

    // MARK: Reading

    func statistics(_ m: HealthMetric, from start: Date, to end: Date) async throws -> [Date: Double] {
        guard let type = Self.quantityType(m) else { return [:] }
        let options: HKStatisticsOptions = m.aggregation == .sum ? .cumulativeSum : .discreteAverage
        let predicate = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end))
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: predicate, options: options, anchorDate: clock.startOfDay(start), intervalComponents: DateComponents(day: 1))
        let collection = try await descriptor.result(for: store)
        var out: [Date: Double] = [:]
        let unit = Self.unit(m)
        collection.enumerateStatistics(from: start, to: end) { stats, _ in
            let q = m.aggregation == .sum ? stats.sumQuantity() : stats.averageQuantity()
            if let q { out[self.clock.startOfDay(stats.startDate)] = q.doubleValue(for: unit) * Self.scale(m) }
        }
        return out
    }

    func latest(_ m: HealthMetric, before end: Date, within days: Int = 7) async throws -> (Double, Date)? {
        guard let type = Self.quantityType(m) else { return nil }
        let pred = HKQuery.predicateForSamples(withStart: clock.addDays(-days, to: end), end: end)
        let d = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: pred)],
                                        sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        guard let s = try await d.result(for: store).first else { return nil }
        return (s.quantity.doubleValue(for: Self.unit(m)) * Self.scale(m), s.endDate)
    }

    func sleep(endingOn day: Date) async throws -> SleepSummary? {
        let dayStart = clock.startOfDay(day)
        let pred = HKQuery.predicateForSamples(withStart: dayStart.addingTimeInterval(-12 * 3600), end: dayStart.addingTimeInterval(12 * 3600))
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: pred)],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        var samples = try await d.result(for: store)
        guard !samples.isEmpty else { return nil }
        typealias V = HKCategoryValueSleepAnalysis
        let staged: Set<Int> = [V.asleepCore.rawValue, V.asleepDeep.rawValue, V.asleepREM.rawValue]
        // iPhone and Watch (and other apps) all write sleep; adding them up double-counts.
        // Keep one source, preferring the one that recorded stages.
        if let source = (samples.first { staged.contains($0.value) } ?? samples.first)?.sourceRevision.source {
            samples = samples.filter { $0.sourceRevision.source == source }
        }
        let hasStages = samples.contains { staged.contains($0.value) }
        func hours(_ values: Set<Int>) -> Double {
            samples.filter { values.contains($0.value) }.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600
        }
        let asleepValues: Set<Int> = hasStages ? staged : [V.asleepUnspecified.rawValue]
        let asleep = samples.filter { asleepValues.contains($0.value) }
        guard let first = asleep.first, let last = asleep.max(by: { $0.endDate < $1.endDate }) else { return nil }
        return SleepSummary(
            start: first.startDate, end: last.endDate, asleepHours: hours(asleepValues),
            deepHours: hasStages ? hours([V.asleepDeep.rawValue]) : nil,
            remHours: hasStages ? hours([V.asleepREM.rawValue]) : nil,
            coreHours: hasStages ? hours([V.asleepCore.rawValue]) : nil,
            awakeHours: hours([V.awake.rawValue]))
    }

    func standHours(_ start: Date, _ end: Date) async throws -> Double {
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.appleStandHour), predicate: pred)], sortDescriptors: [])
        return Double(try await d.result(for: store).filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }.count)
    }

    func mindfulMinutes(_ start: Date, _ end: Date) async throws -> Double {
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.mindfulSession), predicate: pred)], sortDescriptors: [])
        return try await d.result(for: store).reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 60
    }

    func workouts(_ start: Date, _ end: Date) async throws -> [Workout] {
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        let d = HKSampleQueryDescriptor(predicates: [.workout(pred)], sortDescriptors: [SortDescriptor(\.startDate)])
        return try await d.result(for: store).map { w in
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let dist = (w.statistics(for: HKQuantityType(.distanceWalkingRunning)) ?? w.statistics(for: HKQuantityType(.distanceCycling)))?
                .sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo))
            let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
            return Workout(type: Self.workoutName(w.workoutActivityType), start: w.startDate, minutes: w.duration / 60,
                           kcal: kcal, distanceKm: dist, avgHeartRate: hr)
        }
    }

    public func dailySummary(for day: Date) async throws -> DailyHealthSummary {
        let start = clock.startOfDay(day), end = clock.endOfDay(day)
        var s = DailyHealthSummary(day: clock.dayKey(day))
        async let steps = statistics(.steps, from: start, to: end)
        async let active = statistics(.activeEnergy, from: start, to: end)
        async let exercise = statistics(.exerciseMinutes, from: start, to: end)
        async let rhr = statistics(.restingHeartRate, from: start, to: end)
        async let hrv = statistics(.heartRateVariability, from: start, to: end)
        async let resp = statistics(.respiratoryRate, from: start, to: end)
        s.steps = try await steps[start]
        s.activeEnergy = try await active[start]
        s.exerciseMinutes = try await exercise[start]
        s.restingHeartRate = try await rhr[start]
        s.hrv = try await hrv[start]
        s.respiratoryRate = try await resp[start]
        s.standHours = try await standHours(start, end)
        s.mindfulMinutes = try await mindfulMinutes(start, end)
        s.sleep = try await sleep(endingOn: day)
        if let (w, at) = try await latest(.bodyMass, before: end, within: 30) {
            s.bodyMass = w
            s.bodyMassDate = at
        }
        s.bodyFat = try await latest(.bodyFat, before: end, within: 30)?.0
        s.workouts = try await workouts(start, end)
        s.extra = await extras(start, end)
        s.events = await events(start, end)
        return s
    }

    /// Every other metric that has data, queried in parallel. Missing permission just means no data.
    func extras(_ start: Date, _ end: Date) async -> [HealthMetric: Double] {
        await withTaskGroup(of: (HealthMetric, Double?).self) { group in
            for m in HealthMetric.extras {
                group.addTask {
                    if m.aggregation == .latest { return (m, try? await self.latest(m, before: end, within: 90)?.0) }
                    return (m, (try? await self.statistics(m, from: start, to: end))?[start])
                }
            }
            var out: [HealthMetric: Double] = [:]
            for await (m, v) in group { if let v, v.isFinite, v > 0 || m == .wristTemperature { out[m] = v } }
            return out
        }
    }

    func events(_ start: Date, _ end: Date) async -> [String] {
        var out: [(Date, String)] = []
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        for (id, title) in Self.eventTypes {
            let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(id), predicate: pred)],
                                            sortDescriptors: [SortDescriptor(\.startDate)])
            guard let samples = try? await d.result(for: store) else { continue }
            if id == .menstrualFlow {
                if let flow = samples.last { out.append((flow.startDate, "经期记录（\(Self.flowName(flow.value))）")) }
            } else {
                out += samples.map { ($0.startDate, "\(clock.timeString($0.startDate)) \(title)") }
            }
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func flowName(_ v: Int) -> String {
        switch HKCategoryValueVaginalBleeding(rawValue: v) {
        case .light: return "量少"
        case .medium: return "量中"
        case .heavy: return "量多"
        case .none?: return "无"
        default: return "未注明量"
        }
    }

    public func characteristics() async -> HealthCharacteristics {
        var c = HealthCharacteristics()
        c.birthYear = (try? store.dateOfBirthComponents())?.year
        switch (try? store.biologicalSex())?.biologicalSex {
        case .female: c.sex = BodyProfile.Sex.female.rawValue
        case .male: c.sex = BodyProfile.Sex.male.rawValue
        default: break
        }
        c.heightCm = try? await latest(.height, before: Date(), within: 3650)?.0
        return c
    }

    public func dailyValues(_ metric: HealthMetric, days: Int, endingAt end: Date) async throws -> [DailyValue] {
        let last = clock.startOfDay(end)
        let first = clock.addDays(-(max(1, days) - 1), to: last)
        let dayList = (0..<max(1, days)).map { clock.addDays($0, to: first) }
        switch metric {
        case .sleepHours:
            var out: [DailyValue] = []
            for d in dayList { out.append(DailyValue(day: d, value: try await sleep(endingOn: d)?.asleepHours)) }
            return out
        case .standHours:
            var out: [DailyValue] = []
            for d in dayList { out.append(DailyValue(day: d, value: try await standHours(d, clock.endOfDay(d)))) }
            return out
        case .mindfulMinutes:
            var out: [DailyValue] = []
            for d in dayList { out.append(DailyValue(day: d, value: try await mindfulMinutes(d, clock.endOfDay(d)))) }
            return out
        default:
            let stats = try await statistics(metric, from: first, to: clock.endOfDay(last))
            return dayList.map { DailyValue(day: $0, value: stats[$0]) }
        }
    }

    // MARK: Writing

    public func save(_ measurement: BodyMeasurement, at date: Date) async throws {
        switch measurement {
        case .weight(let kg):
            try await store.save(HKQuantitySample(type: HKQuantityType(.bodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg), start: date, end: date))
        case .bodyFat(let pct):
            try await store.save(HKQuantitySample(type: HKQuantityType(.bodyFatPercentage), quantity: HKQuantity(unit: .percent(), doubleValue: pct / 100), start: date, end: date))
        case .bloodPressure(let sys, let dia):
            let mmHg = HKUnit.millimeterOfMercury()
            let s = HKQuantitySample(type: HKQuantityType(.bloodPressureSystolic), quantity: HKQuantity(unit: mmHg, doubleValue: sys), start: date, end: date)
            let d = HKQuantitySample(type: HKQuantityType(.bloodPressureDiastolic), quantity: HKQuantity(unit: mmHg, doubleValue: dia), start: date, end: date)
            try await store.save(HKCorrelation(type: HKCorrelationType(.bloodPressure), start: date, end: date, objects: [s, d]))
        case .restingHeartRate:
            break // Apple Watch owns resting heart rate; manual values stay in the conversation only.
        }
    }

    public func save(meal: Meal) async throws {
        try await deleteMeal(id: meal.id)
        let t = meal.totals
        let meta: [String: Any] = [
            HKMetadataKeyFoodType: meal.items.map(\.name).joined(separator: "、"),
            Self.mealIDKey: meal.id.uuidString,
        ]
        func sample(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ v: Double) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: v), start: meal.eatenAt, end: meal.eatenAt, metadata: meta)
        }
        let objects: Set<HKSample> = [
            sample(.dietaryEnergyConsumed, .kilocalorie(), t.kcal),
            sample(.dietaryProtein, .gram(), t.protein),
            sample(.dietaryFatTotal, .gram(), t.fat),
            sample(.dietaryCarbohydrates, .gram(), t.carbs),
        ]
        let food = HKCorrelation(type: HKCorrelationType(.food), start: meal.eatenAt, end: meal.eatenAt, objects: objects, metadata: meta)
        try await store.save(food)
    }

    public func deleteMeal(id: UUID) async throws {
        let pred = HKQuery.predicateForObjects(withMetadataKey: Self.mealIDKey, allowedValues: [id.uuidString])
        for t in [HKQuantityTypeIdentifier.dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates] {
            _ = try? await store.deleteObjects(of: HKQuantityType(t), predicate: pred)
        }
    }

    public func saveWater(ml: Double, at date: Date) async throws {
        try await store.save(HKQuantitySample(type: HKQuantityType(.dietaryWater), quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: ml), start: date, end: date))
    }

    public func save(mood: MoodEntry) async throws {
        let labels = mood.labels.compactMap(Self.stateOfMindLabel)
        let som = HKStateOfMind(date: mood.at, kind: .momentaryEmotion, valence: Double(mood.valence) / 3, labels: labels, associations: [])
        try await store.save(som)
    }

    // MARK: Mapping

    static func stateOfMindLabel(_ s: String) -> HKStateOfMind.Label? {
        switch s.lowercased() {
        case "happy", "开心", "快乐": return .happy
        case "joyful", "喜悦": return .joyful
        case "calm", "平静": return .calm
        case "peaceful", "安宁": return .peaceful
        case "content", "满足": return .content
        case "satisfied", "满意": return .satisfied
        case "grateful", "感恩", "感激": return .grateful
        case "excited", "兴奋": return .excited
        case "hopeful", "有希望": return .hopeful
        case "proud", "自豪": return .proud
        case "relieved", "如释重负", "放松": return .relieved
        case "confident", "自信": return .confident
        case "amused", "好笑": return .amused
        case "anxious", "焦虑": return .anxious
        case "worried", "担心": return .worried
        case "stressed", "压力大", "紧张": return .stressed
        case "overwhelmed", "不堪重负": return .overwhelmed
        case "sad", "难过", "伤心": return .sad
        case "lonely", "孤独": return .lonely
        case "drained", "疲惫", "累": return .drained
        case "frustrated", "沮丧": return .frustrated
        case "discouraged", "气馁": return .discouraged
        case "disappointed", "失望": return .disappointed
        case "irritated", "烦躁": return .irritated
        case "annoyed", "恼火": return .annoyed
        case "angry", "生气": return .angry
        case "scared", "害怕": return .scared
        case "guilty", "内疚": return .guilty
        case "ashamed", "羞愧": return .ashamed
        case "hopeless", "绝望": return .hopeless
        case "indifferent", "无感": return .indifferent
        default: return nil
        }
    }

    static func workoutName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "瑜伽"
        case .hiking: return "徒步"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船"
        case .dance, .cardioDance, .socialDance: return "舞蹈"
        case .coreTraining: return "核心训练"
        case .pilates: return "普拉提"
        case .badminton: return "羽毛球"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .tableTennis: return "乒乓球"
        case .tennis: return "网球"
        case .mindAndBody: return "身心训练"
        case .stairClimbing, .stairs: return "爬楼"
        case .jumpRope: return "跳绳"
        case .cooldown: return "放松"
        default: return "其他运动"
        }
    }
}
#endif
