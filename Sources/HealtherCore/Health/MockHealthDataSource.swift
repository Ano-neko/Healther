import Foundation

/// Deterministic fake Apple Watch data for development on Linux and in the simulator.
/// The same day always produces the same numbers; manual writes persist in `mock_samples`.
public final class MockHealthDataSource: HealthDataSource {
    let db: SQLiteDatabase
    let clock: DayClock
    let seed: UInt64
    public var isMock: Bool { true }

    public init(db: SQLiteDatabase, clock: DayClock = DayClock(), seed: UInt64 = 7) {
        self.db = db
        self.clock = clock
        self.seed = seed
    }

    public func requestAuthorization() async throws {}

    /// SplitMix64 keyed by (day, salt) → uniform 0..<1.
    func noise(_ day: Date, _ salt: UInt64) -> Double {
        let dayIndex = UInt64(max(0, Int(clock.startOfDay(day).timeIntervalSince1970 / 86_400)))
        var z = dayIndex &* 0x9E3779B97F4A7C15 &+ salt &* 0xBF58476D1CE4E5B9 &+ seed
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    func isWeekend(_ day: Date) -> Bool {
        let w = clock.calendar.component(.weekday, from: day)
        return w == 1 || w == 7
    }

    func sleep(endingOn day: Date) -> SleepSummary {
        let base = clock.startOfDay(day)
        let late = isWeekend(day) ? 0.8 : 0.0
        let bedtime = base.addingTimeInterval((-1.2 + noise(day, 1) * 2.6 + late) * 3600) // ~22:50–01:30
        let asleep = 5.2 + noise(day, 2) * 2.8 + late * 0.6
        let awake = 0.2 + noise(day, 3) * 0.5
        let deep = asleep * (0.11 + noise(day, 4) * 0.09)
        let rem = asleep * (0.18 + noise(day, 5) * 0.08)
        return SleepSummary(start: bedtime, end: bedtime.addingTimeInterval((asleep + awake) * 3600), asleepHours: asleep,
                            deepHours: deep, remHours: rem, coreHours: asleep - deep - rem, awakeHours: awake)
    }

    func synthetic(_ metric: HealthMetric, _ day: Date) -> Double? {
        let todayFraction: Double = {
            let now = Date()
            guard clock.startOfDay(now) == clock.startOfDay(day) else { return 1 }
            return min(1, max(0, (now.timeIntervalSince(clock.startOfDay(now)) / 3600 - 7) / 15))
        }()
        let active = noise(day, 10) > 0.35
        switch metric {
        case .steps: return ((active ? 7500 : 3500) + noise(day, 11) * 6000) * todayFraction
        case .activeEnergy: return ((active ? 420 : 210) + noise(day, 12) * 260) * todayFraction
        case .exerciseMinutes: return ((active ? 32 : 6) + noise(day, 13) * 25) * todayFraction
        case .standHours: return ((8 + noise(day, 14) * 5) * todayFraction).rounded()
        case .restingHeartRate: return 58 + noise(day, 15) * 8 + (sleep(endingOn: day).asleepHours < 6 ? 3 : 0)
        case .heartRateVariability: return 38 + noise(day, 16) * 22 - (sleep(endingOn: day).asleepHours < 6 ? 6 : 0)
        case .respiratoryRate: return 13.5 + noise(day, 17) * 2.5
        case .vo2Max: return 41.5 + noise(day, 18) * 0.8
        case .bodyMass:
            let days = day.timeIntervalSince1970 / 86_400
            return 68.0 + sin(days / 9) * 0.6 + (noise(day, 19) - 0.5) * 0.5
        case .bodyFat: return 19.5 + (noise(day, 20) - 0.5) * 1.2
        case .sleepHours: return sleep(endingOn: day).asleepHours
        case .mindfulMinutes: return noise(day, 21) > 0.75 ? 10 : 0
        case .dietaryEnergy, .water: return nil
        }
    }

    func manual(_ metric: String, from: Date, to: Date) throws -> [Row] {
        try db.query("SELECT * FROM mock_samples WHERE metric = ? AND at >= ? AND at < ? ORDER BY at", [metric, from, to])
    }

    func value(_ metric: HealthMetric, on day: Date) throws -> Double? {
        let start = clock.startOfDay(day), end = clock.endOfDay(day)
        switch metric {
        case .bodyMass, .bodyFat:
            // Manual entries override synthetic ones; "latest on or before".
            if let r = try db.queryOne("SELECT value FROM mock_samples WHERE metric = ? AND at < ? ORDER BY at DESC LIMIT 1",
                                       [metric.rawValue, end]),
               let v = r.double("value"),
               let manualDay = try db.queryOne("SELECT at FROM mock_samples WHERE metric = ? AND at < ? ORDER BY at DESC LIMIT 1",
                                               [metric.rawValue, end])?.date("at"),
               end.timeIntervalSince(manualDay) < 3 * 86_400 {
                return v
            }
            // Pretend the user weighs in roughly every other day.
            if metric == .bodyMass, noise(day, 30) < 0.45 { return nil }
            return synthetic(metric, day)
        case .dietaryEnergy:
            return try db.queryOne("SELECT sum(kcal) k FROM meals WHERE status='confirmed' AND eaten_at >= ? AND eaten_at < ?",
                                   [start, end])?.double("k")
        case .water:
            return try db.queryOne("SELECT sum(ml) v FROM water_entries WHERE at >= ? AND at < ?", [start, end])?.double("v")
        default:
            if day > Date() { return nil }
            return synthetic(metric, day)
        }
    }

    public func dailySummary(for day: Date) async throws -> DailyHealthSummary {
        var s = DailyHealthSummary(day: clock.dayKey(day))
        let isFuture = clock.startOfDay(day) > Date()
        guard !isFuture else { return s }
        s.steps = try value(.steps, on: day)
        s.activeEnergy = try value(.activeEnergy, on: day)
        s.exerciseMinutes = try value(.exerciseMinutes, on: day)
        s.standHours = try value(.standHours, on: day)
        s.restingHeartRate = try value(.restingHeartRate, on: day)
        s.hrv = try value(.heartRateVariability, on: day)
        s.respiratoryRate = try value(.respiratoryRate, on: day)
        s.mindfulMinutes = try value(.mindfulMinutes, on: day)
        s.sleep = sleep(endingOn: day)
        // Latest weight within the past week.
        for back in 0..<7 {
            let d = clock.addDays(-back, to: day)
            if let w = try value(.bodyMass, on: d) {
                s.bodyMass = w
                s.bodyMassDate = d
                s.bodyFat = try value(.bodyFat, on: d)
                break
            }
        }
        if (s.exerciseMinutes ?? 0) > 25 {
            let kinds = ["跑步", "力量训练", "骑行", "快走", "游泳"]
            let kind = kinds[Int(noise(day, 40) * Double(kinds.count))]
            let start = clock.startOfDay(day).addingTimeInterval((18 + noise(day, 41) * 2) * 3600)
            if start < Date() {
                let mins = (s.exerciseMinutes ?? 30) * 0.85
                s.workouts = [Workout(type: kind, start: start, minutes: mins, kcal: mins * 8.5,
                                      distanceKm: kind == "跑步" ? mins / 6.2 : nil, avgHeartRate: 128 + noise(day, 42) * 25)]
            }
        }
        return s
    }

    public func dailyValues(_ metric: HealthMetric, days: Int, endingAt end: Date) async throws -> [DailyValue] {
        try (0..<max(1, days)).reversed().map { back in
            let d = clock.startOfDay(clock.addDays(-back, to: end))
            return DailyValue(day: d, value: try value(metric, on: d))
        }
    }

    public func save(_ measurement: BodyMeasurement, at date: Date) async throws {
        switch measurement {
        case .weight(let kg): try insert("weight", date, kg)
        case .bodyFat(let pct): try insert("body_fat", date, pct)
        case .bloodPressure(let s, let d): try insert("blood_pressure", date, s, d)
        case .restingHeartRate(let bpm): try insert("resting_heart_rate_manual", date, bpm)
        }
    }

    public func save(meal: Meal) async throws {}  // meals table is already the mock's source of truth
    public func deleteMeal(id: UUID) async throws {}
    public func saveWater(ml: Double, at date: Date) async throws {}  // water_entries is the source of truth

    public func save(mood: MoodEntry) async throws {
        try insert("mood", mood.at, Double(mood.valence))
    }

    private func insert(_ metric: String, _ at: Date, _ v: Double, _ v2: Double? = nil) throws {
        try db.execute("INSERT INTO mock_samples(metric, at, value, value2) VALUES (?, ?, ?, ?)", [metric, at, v, v2])
    }
}
