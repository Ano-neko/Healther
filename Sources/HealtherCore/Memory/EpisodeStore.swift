import Foundation

/// Daily diary entries written by reflection: what happened, how the user felt, what mattered.
/// Recent episodes give the agent a sense of continuity across days.
public final class EpisodeStore: Sendable {
    let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    public struct Episode: Sendable, Hashable {
        public var day: String
        public var summary: String
        public var mood: String?
        public var highlights: [String]
        public var updatedAt: Date
    }

    func episode(_ r: Row) -> Episode {
        Episode(day: r.string("day") ?? "", summary: r.string("summary") ?? "", mood: r.string("mood"),
                highlights: (try? JSONDecoder().decode([String].self, from: Data((r.string("highlights") ?? "[]").utf8))) ?? [],
                updatedAt: r.date("updated_at") ?? Date())
    }

    public func save(day: String, summary: String, mood: String?, highlights: [String], now: Date = Date()) throws {
        let h = String(decoding: try JSONEncoder().encode(highlights), as: UTF8.self)
        try db.execute(
            """
            INSERT INTO episodes(day, summary, mood, highlights, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET summary = excluded.summary, mood = excluded.mood, highlights = excluded.highlights,
                updated_at = excluded.updated_at
            """, [day, summary, mood, h, now, now])
    }

    public func get(day: String) throws -> Episode? {
        try db.queryOne("SELECT * FROM episodes WHERE day = ?", [day]).map(episode)
    }

    /// Most recent first.
    public func recent(_ n: Int, before day: String) throws -> [Episode] {
        try db.query("SELECT * FROM episodes WHERE day < ? ORDER BY day DESC LIMIT ?", [day, n]).map(episode)
    }

    public func range(from: String, to: String) throws -> [Episode] {
        try db.query("SELECT * FROM episodes WHERE day >= ? AND day <= ? ORDER BY day", [from, to]).map(episode)
    }
}
