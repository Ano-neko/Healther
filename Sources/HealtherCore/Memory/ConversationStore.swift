import Foundation

/// L4: the full conversation log. One continuous conversation (companion style), never "new chat".
///
/// The prompt sees a rolling summary of compacted messages plus the uncompacted tail.
/// Raw rows are kept forever for the UI and for daily reflection.
public final class ConversationStore: Sendable {
    let db: SQLiteDatabase
    let kv: KeyValueStore
    public init(db: SQLiteDatabase) {
        self.db = db
        kv = KeyValueStore(db: db)
    }

    public struct Attachment: Codable, Sendable, Hashable {
        public var file: String
        public var mimeType: String
        public init(file: String, mimeType: String) {
            self.file = file
            self.mimeType = mimeType
        }
    }

    public struct Payload: Codable, Sendable, Hashable {
        public var toolCalls: [ToolCall]?
        public var toolCallID: String?
        public var toolName: String?
        public var reasoning: String?
        public var attachments: [Attachment]?
        public var usage: ChatUsage?
        /// Set on messages she sent on her own (wake greeting, meal check-in, …): the ProactiveKind raw value.
        public var proactive: String?
        public init() {}
    }

    public struct Message: Sendable, Hashable, Identifiable {
        public var id: Int
        public var turnID: String
        public var createdAt: Date
        public var role: ChatRole
        public var content: String
        public var payload: Payload
        public var compacted: Bool
    }

    func message(_ r: Row) -> Message? {
        guard let id = r.int("id"), let role = ChatRole(rawValue: r.string("role") ?? "") else { return nil }
        let payload = r.string("payload").flatMap { try? JSONDecoder().decode(Payload.self, from: Data($0.utf8)) } ?? Payload()
        return Message(id: id, turnID: r.string("turn_id") ?? "", createdAt: r.date("created_at") ?? Date(), role: role,
                       content: r.string("content") ?? "", payload: payload, compacted: r.bool("compacted"))
    }

    @discardableResult
    public func append(turnID: String, role: ChatRole, content: String, payload: Payload = Payload(), at: Date = Date()) throws -> Message {
        let p = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try db.execute("INSERT INTO messages(turn_id, created_at, role, content, payload) VALUES (?, ?, ?, ?, ?)",
                       [turnID, at, role.rawValue, content, p])
        return Message(id: Int(db.lastInsertRowID), turnID: turnID, createdAt: at, role: role, content: content, payload: payload, compacted: false)
    }

    public func uncompacted() throws -> [Message] {
        try db.query("SELECT * FROM messages WHERE compacted = 0 ORDER BY id").compactMap(message)
    }

    public func history(limit: Int = 200, beforeID: Int? = nil) throws -> [Message] {
        let rows = try db.query("SELECT * FROM messages WHERE id < ? ORDER BY id DESC LIMIT ?", [beforeID ?? Int.max, limit])
        return rows.compactMap(message).reversed()
    }

    public func messages(from: Date, to: Date) throws -> [Message] {
        try db.query("SELECT * FROM messages WHERE created_at >= ? AND created_at < ? ORDER BY id", [from, to]).compactMap(message)
    }

    /// Distinct local days that have user messages, for reflection bookkeeping.
    public func firstMessageDate() throws -> Date? {
        try db.queryOne("SELECT min(created_at) t FROM messages WHERE role = 'user'")?.date("t")
    }

    public func markCompacted(throughID id: Int) throws {
        try db.execute("UPDATE messages SET compacted = 1 WHERE id <= ? AND compacted = 0", [id])
    }

    public var rollingSummary: String? {
        get { kv.get("conversation.rolling_summary") }
    }

    public func setRollingSummary(_ s: String?) throws { try kv.set("conversation.rolling_summary", s) }

    public func deleteTurn(_ turnID: String) throws {
        try db.execute("DELETE FROM messages WHERE turn_id = ?", [turnID])
    }

    public func clearAll() throws {
        try db.execute("DELETE FROM messages")
        try setRollingSummary(nil)
    }
}
