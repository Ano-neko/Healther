import Foundation

/// Goals, mood log and water log — the local source of truth for things Apple Health
/// either doesn't store or that we want to show without a HealthKit round-trip.
public final class WellbeingStore: Sendable {
    let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    public enum GoalKind: String, CaseIterable, Codable, Sendable {
        case dailyKcal = "daily_kcal"
        case proteinG = "protein_g"
        case steps
        case exerciseMinutes = "exercise_minutes"
        case sleepHours = "sleep_hours"
        case bedtime = "bedtime"
        case waterML = "water_ml"
        case weightKg = "weight_kg"

        public var title: String {
            switch self {
            case .dailyKcal: return "每日热量"
            case .proteinG: return "每日蛋白质"
            case .steps: return "每日步数"
            case .exerciseMinutes: return "每日锻炼"
            case .sleepHours: return "睡眠时长"
            case .bedtime: return "入睡时间"
            case .waterML: return "每日饮水"
            case .weightKg: return "目标体重"
            }
        }

        public var unit: String {
            switch self {
            case .dailyKcal: return "kcal"
            case .proteinG: return "g"
            case .steps: return "步"
            case .exerciseMinutes: return "分钟"
            case .sleepHours: return "小时"
            case .bedtime: return "点(24h)"
            case .waterML: return "ml"
            case .weightKg: return "kg"
            }
        }
    }

    public struct Goal: Sendable, Hashable {
        public var kind: GoalKind
        public var target: Double
        public var note: String?
    }

    public func setGoal(_ kind: GoalKind, target: Double?, note: String? = nil, now: Date = Date()) throws {
        if let target {
            try db.execute(
                """
                INSERT INTO goals(kind, target, note, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind) DO UPDATE SET target = excluded.target, note = excluded.note, updated_at = excluded.updated_at
                """, [kind.rawValue, target, note, now])
        } else {
            try db.execute("DELETE FROM goals WHERE kind = ?", [kind.rawValue])
        }
    }

    public func goals() throws -> [Goal] {
        try db.query("SELECT * FROM goals").compactMap { r in
            guard let k = GoalKind(rawValue: r.string("kind") ?? ""), let t = r.double("target") else { return nil }
            return Goal(kind: k, target: t, note: r.string("note"))
        }.sorted { GoalKind.allCases.firstIndex(of: $0.kind)! < GoalKind.allCases.firstIndex(of: $1.kind)! }
    }

    public func goal(_ kind: GoalKind) -> Goal? { (try? goals())?.first { $0.kind == kind } }

    // MARK: Mood

    public func addMood(_ m: MoodEntry) throws {
        try db.execute("INSERT INTO mood_entries(at, valence, labels, note) VALUES (?, ?, ?, ?)",
                       [m.at, m.valence, m.labels.joined(separator: ","), m.note])
    }

    public func moods(from: Date, to: Date) throws -> [MoodEntry] {
        try db.query("SELECT * FROM mood_entries WHERE at >= ? AND at < ? ORDER BY at", [from, to]).map { r in
            MoodEntry(at: r.date("at") ?? Date(), valence: r.int("valence") ?? 0,
                      labels: (r.string("labels") ?? "").split(separator: ",").map(String.init), note: r.string("note"))
        }
    }

    // MARK: Water

    public func addWater(ml: Double, at: Date) throws {
        try db.execute("INSERT INTO water_entries(at, ml) VALUES (?, ?)", [at, ml])
    }

    public func water(from: Date, to: Date) throws -> Double {
        (try db.queryOne("SELECT sum(ml) v FROM water_entries WHERE at >= ? AND at < ?", [from, to])?.double("v")) ?? 0
    }
}
