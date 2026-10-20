import Foundation

/// Height, birth year and sex as the user entered them. Every field optional, so older
/// saves keep decoding as fields are added.
public struct BodyProfile: Codable, Sendable, Equatable {
    public var heightCm: Double?
    public var birthYear: Int?
    /// One of `Sex` raw values; a plain string so an unknown value never breaks decoding.
    public var sex: String?

    public enum Sex: String, CaseIterable, Sendable {
        case female, male

        public var title: String { self == .female ? "女" : "男" }
    }

    public init(heightCm: Double? = nil, birthYear: Int? = nil, sex: String? = nil) {
        self.heightCm = heightCm
        self.birthYear = birthYear
        self.sex = sex
    }

    public var isEmpty: Bool { heightCm == nil && birthYear == nil && sex == nil }

    /// Fields set here win; the rest come from `fallback`.
    public func filled(from fallback: BodyProfile) -> BodyProfile {
        BodyProfile(heightCm: heightCm ?? fallback.heightCm, birthYear: birthYear ?? fallback.birthYear, sex: sex ?? fallback.sex)
    }

    public func age(now: Date, calendar: Calendar) -> Int? {
        birthYear.map { calendar.component(.year, from: now) - $0 }
    }
}

/// The body basics plus hand-logged weights (for anyone without a smart scale).
/// Weights also go to Apple Health when allowed; this copy keeps working when it isn't.
public final class BodyStore: Sendable {
    let db: SQLiteDatabase
    let kv: KeyValueStore

    public init(db: SQLiteDatabase, kv: KeyValueStore) {
        self.db = db
        self.kv = kv
    }

    /// What the user typed in (settings or chat).
    public var manual: BodyProfile {
        kv.get("body.profile").flatMap { try? JSONDecoder().decode(BodyProfile.self, from: Data($0.utf8)) } ?? BodyProfile()
    }

    public func setManual(_ p: BodyProfile) throws {
        try kv.set("body.profile", p.isEmpty ? nil : String(decoding: try JSONEncoder().encode(p), as: UTF8.self))
    }

    /// Last values read from Apple Health, cached so the prompt can be built without a HealthKit round-trip.
    public var fromHealth: BodyProfile {
        kv.get("body.health").flatMap { try? JSONDecoder().decode(BodyProfile.self, from: Data($0.utf8)) } ?? BodyProfile()
    }

    public func setFromHealth(_ c: HealthCharacteristics) throws {
        let p = BodyProfile(heightCm: c.heightCm, birthYear: c.birthYear, sex: c.sex)
        guard p != fromHealth else { return }
        try kv.set("body.health", p.isEmpty ? nil : String(decoding: try JSONEncoder().encode(p), as: UTF8.self))
    }

    /// Manual entries first, Apple Health for the rest.
    public var current: BodyProfile { manual.filled(from: fromHealth) }

    // MARK: Weight log

    public struct WeightEntry: Sendable, Hashable {
        public var at: Date
        public var kg: Double
    }

    public func addWeight(kg: Double, at: Date) throws {
        try db.execute("INSERT INTO weight_entries(at, kg) VALUES (?, ?)", [at, kg])
    }

    public func weights(from: Date, to: Date) throws -> [WeightEntry] {
        try db.query("SELECT at, kg FROM weight_entries WHERE at >= ? AND at < ? ORDER BY at", [from, to]).compactMap { r in
            guard let at = r.date("at"), let kg = r.double("kg") else { return nil }
            return WeightEntry(at: at, kg: kg)
        }
    }

    public func latestWeight(before end: Date, since start: Date) throws -> WeightEntry? {
        try weights(from: start, to: end).last
    }
}

extension HealtherServices {
    /// Apple Health's day summary, with hand-logged weight filled in when it is the newer reading.
    public func healthSummary(for day: Date) async throws -> DailyHealthSummary {
        var h = try await health.dailySummary(for: day)
        let end = clock.endOfDay(day)
        if let w = try body.latestWeight(before: end, since: clock.addDays(-30, to: end)), w.at > (h.bodyMassDate ?? .distantPast) {
            h.bodyMass = w.kg
            h.bodyMassDate = w.at
        }
        return h
    }

    /// Apple Health's daily values; for weight, days without a reading there take the hand-logged one.
    public func dailyValues(_ metric: HealthMetric, days: Int, endingAt end: Date) async throws -> [DailyValue] {
        var values = try await health.dailyValues(metric, days: days, endingAt: end)
        guard metric == .bodyMass, let first = values.first?.day else { return values }
        let logged = try body.weights(from: first, to: clock.endOfDay(end))
        for i in values.indices where values[i].value == nil {
            let d = values[i].day
            values[i].value = logged.last { clock.startOfDay($0.at) == d }?.kg
        }
        return values
    }

    /// Refreshes the cached Apple Health body characteristics. Cheap; call before building a prompt.
    public func syncBodyFromHealth() async {
        try? body.setFromHealth(await health.characteristics())
        adoptProfileHeight()
    }

    /// Before body profiles existed, height went into the free-form profile ("身高：175cm").
    func adoptProfileHeight() {
        guard body.manual.heightCm == nil,
              let entry = (try? profile.all())?.first(where: { $0.section == .basics && $0.key.contains("身高") }),
              let r = entry.value.range(of: #"\d{2,3}(\.\d)?"#, options: .regularExpression),
              let h = Double(entry.value[r]), (80...250).contains(h) else { return }
        var p = body.manual
        p.heightCm = h
        try? body.setManual(p)
    }
}
