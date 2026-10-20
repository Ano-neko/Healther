import Foundation

/// L3 memory: atomic long-term memories with full-text recall.
///
/// Ranking = text relevance (bm25 over CJK bigrams) × importance × recency.
/// Memories are never edited in place: a changed fact supersedes the old one,
/// so history stays auditable and stale facts drop out of recall.
public final class MemoryStore: Sendable {
    let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    public enum Kind: String, CaseIterable, Codable, Sendable {
        case fact        // 客观信息：住在哪、养了猫
        case preference  // 喜好与厌恶
        case health      // 身体相关：症状、伤病、体检
        case event       // 生活事件：换工作、旅行、考试
        case emotion     // 情绪状态与其起因
        case insight     // 从数据里观察到的规律
        case commitment  // 约定、计划、答应过的事

        public var title: String {
            switch self {
            case .fact: return "事实"
            case .preference: return "偏好"
            case .health: return "健康"
            case .event: return "事件"
            case .emotion: return "情绪"
            case .insight: return "洞察"
            case .commitment: return "约定"
            }
        }
    }

    public struct Memory: Sendable, Hashable, Identifiable {
        public var id: Int
        public var kind: Kind
        public var content: String
        public var tags: [String]
        public var importance: Int
        public var createdAt: Date
        public var updatedAt: Date
        public var recallCount: Int
        public var supersededBy: Int?

        public func json(clock: DayClock) -> JSONValue {
            [
                "memory_id": .number(Double(id)), "kind": .string(kind.rawValue), "content": .string(content),
                "importance": .number(Double(importance)), "date": .string(clock.dayKey(createdAt)),
            ]
        }
    }

    func memory(_ r: Row) -> Memory? {
        guard let id = r.int("id"), let kind = Kind(rawValue: r.string("kind") ?? "") else { return nil }
        return Memory(
            id: id, kind: kind, content: r.string("content") ?? "",
            tags: (r.string("tags") ?? "").split(separator: ",").map(String.init),
            importance: r.int("importance") ?? 3, createdAt: r.date("created_at") ?? Date(),
            updatedAt: r.date("updated_at") ?? Date(), recallCount: r.int("recall_count") ?? 0,
            supersededBy: r.int("superseded_by"))
    }

    /// Adds a memory. If `replaces` is set, that memory is marked superseded.
    /// Near-duplicates of an active memory are merged instead of inserted.
    @discardableResult
    public func remember(_ content: String, kind: Kind, importance: Int = 3, tags: [String] = [],
                         replaces: Int? = nil, source: String = "agent", now: Date = Date()) throws -> Memory {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let imp = max(1, min(5, importance))
        return try db.transaction {
            if replaces == nil, let dup = try nearDuplicate(of: text) {
                try db.execute("UPDATE memories SET updated_at = ?, importance = max(importance, ?) WHERE id = ?", [now, imp, dup.id])
                return try get(dup.id)!
            }
            try db.execute(
                "INSERT INTO memories(kind, content, tags, importance, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [kind.rawValue, text, tags.joined(separator: ","), imp, source, now, now])
            let id = Int(db.lastInsertRowID)
            try db.execute("INSERT INTO memories_fts(rowid, tokens) VALUES (?, ?)",
                           [id, SearchTokenizer.indexTokens(text + " " + tags.joined(separator: " "))])
            if let old = replaces, old != id {
                try db.execute("UPDATE memories SET superseded_by = ? WHERE id = ? AND superseded_by IS NULL", [id, old])
            }
            return try get(id)!
        }
    }

    public func get(_ id: Int) throws -> Memory? {
        try db.queryOne("SELECT * FROM memories WHERE id = ?", [id]).flatMap(memory)
    }

    /// Soft delete: superseded by nothing (-1) keeps the row for audit but removes it from recall.
    public func forget(_ id: Int) throws {
        try db.transaction {
            try db.execute("UPDATE memories SET superseded_by = -1 WHERE id = ?", [id])
            try db.execute("DELETE FROM memories_fts WHERE rowid = ?", [id])
        }
    }

    /// Hard delete, for the user's "forget this" in the UI.
    public func erase(_ id: Int) throws {
        try db.transaction {
            try db.execute("UPDATE memories SET superseded_by = NULL WHERE superseded_by = ?", [id])
            try db.execute("DELETE FROM memories WHERE id = ?", [id])
            try db.execute("DELETE FROM memories_fts WHERE rowid = ?", [id])
        }
    }

    public func active(limit: Int = 500) throws -> [Memory] {
        try db.query("SELECT * FROM memories WHERE superseded_by IS NULL ORDER BY importance DESC, updated_at DESC LIMIT ?", [limit])
            .compactMap(memory)
    }

    public func recent(days: Int, now: Date = Date(), limit: Int = 30) throws -> [Memory] {
        try db.query("SELECT * FROM memories WHERE superseded_by IS NULL AND created_at >= ? ORDER BY created_at DESC LIMIT ?",
                     [now.addingTimeInterval(-Double(days) * 86_400), limit]).compactMap(memory)
    }

    public var count: Int { (try? db.queryOne("SELECT count(*) n FROM memories WHERE superseded_by IS NULL")?.int("n")) ?? 0 }

    public struct Hit: Sendable {
        public var memory: Memory
        public var score: Double
    }

    /// Ranked recall. `minScore` filters weak matches for automatic (not explicit) recall.
    public func recall(_ query: String, limit: Int = 8, minScore: Double = 0, touch: Bool = true, now: Date = Date()) throws -> [Hit] {
        guard let match = SearchTokenizer.matchExpression(query) else { return [] }
        let rows = try db.query(
            """
            SELECT m.*, bm25(memories_fts) AS rank FROM memories_fts JOIN memories m ON m.id = memories_fts.rowid
            WHERE memories_fts MATCH ? AND m.superseded_by IS NULL ORDER BY rank LIMIT 60
            """, [match])
        let hits: [Hit] = rows.compactMap { r in
            guard let m = memory(r) else { return nil }
            let relevance = -(r.double("rank") ?? 0)                    // bm25: larger is better after negation
            let coverage = SearchTokenizer.coverage(of: query, in: m.content + " " + m.tags.joined(separator: " "))
            let ageDays = max(0, now.timeIntervalSince(m.updatedAt) / 86_400)
            let recency = 0.5 + 0.5 * exp(-ageDays / 45)               // floors at 0.5: old memories still count
            let weight = 0.7 + 0.15 * Double(m.importance)
            let score = (relevance + 4 * coverage) * weight * recency
            return Hit(memory: m, score: score)
        }
        let top = hits.filter { $0.score >= minScore }.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
        if touch, !top.isEmpty {
            let ids = top.map { String($0.memory.id) }.joined(separator: ",")
            try db.execute("UPDATE memories SET recall_count = recall_count + 1, last_recalled_at = ? WHERE id IN (\(ids))", [now])
        }
        return top
    }

    /// An active memory whose text is essentially the same (high bigram overlap both ways).
    func nearDuplicate(of text: String) throws -> Memory? {
        guard let match = SearchTokenizer.matchExpression(text) else { return nil }
        let rows = try db.query(
            """
            SELECT m.* FROM memories_fts JOIN memories m ON m.id = memories_fts.rowid
            WHERE memories_fts MATCH ? AND m.superseded_by IS NULL ORDER BY bm25(memories_fts) LIMIT 5
            """, [match])
        for r in rows {
            guard let m = memory(r) else { continue }
            if SearchTokenizer.coverage(of: text, in: m.content) > 0.85, SearchTokenizer.coverage(of: m.content, in: text) > 0.85 {
                return m
            }
        }
        return nil
    }
}
