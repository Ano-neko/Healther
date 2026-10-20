import Foundation

/// L1 memory: a small structured profile rendered into every prompt.
/// Kept deliberately compact (target ≤ ~1.5k tokens) — details belong in long-term memories.
public final class ProfileStore: Sendable {
    let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    public enum Section: String, CaseIterable, Sendable {
        case basics = "basics"
        case health = "health"
        case goals = "goals"
        case diet = "diet"
        case routine = "routine"
        case personality = "personality"
        case relationship = "relationship"

        public var title: String {
            switch self {
            case .basics: return "基本信息"
            case .health: return "身体与健康状况"
            case .goals: return "目标与计划"
            case .diet: return "饮食偏好与习惯"
            case .routine: return "作息与运动习惯"
            case .personality: return "性格与沟通偏好"
            case .relationship: return "我们之间"
            }
        }

        public var hint: String {
            switch self {
            case .basics: return "称呼、性别、出生年份、身高、所在城市、职业"
            case .health: return "慢性病、过敏、用药、伤病、体检异常"
            case .goals: return "减脂/增肌/睡眠/情绪等长期目标与当前计划"
            case .diet: return "口味、忌口、常吃的店、饮食模式"
            case .routine: return "上下班时间、睡觉习惯、运动类型和频率"
            case .personality: return "喜欢的交流方式、雷区、幽默感"
            case .relationship: return "给我起的名字、我们的梗、约定"
            }
        }
    }

    public struct Entry: Sendable, Hashable {
        public var section: Section
        public var key: String
        public var value: String
        public var updatedAt: Date
    }

    public func set(_ section: Section, _ key: String, _ value: String?, now: Date = Date()) throws {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            try db.execute(
                """
                INSERT INTO profile(section, key, value, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(section, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """, [section.rawValue, k, String(v.prefix(300)), now])
        } else {
            try db.execute("DELETE FROM profile WHERE section = ? AND key = ?", [section.rawValue, k])
        }
    }

    public func all() throws -> [Entry] {
        try db.query("SELECT * FROM profile ORDER BY section, updated_at").compactMap { r in
            guard let s = Section(rawValue: r.string("section") ?? "") else { return nil }
            return Entry(section: s, key: r.string("key") ?? "", value: r.string("value") ?? "", updatedAt: r.date("updated_at") ?? Date())
        }
    }

    public func value(_ section: Section, _ key: String) -> String? {
        try? db.queryOne("SELECT value FROM profile WHERE section = ? AND key = ?", [section.rawValue, key])?.string("value")
    }

    /// Markdown rendering for the system prompt. Stable ordering keeps the prompt prefix cacheable.
    public func render() throws -> String {
        let entries = try all()
        guard !entries.isEmpty else { return "（还没有记录。在聊天中自然地了解对方，用 update_profile 记下来。）" }
        var out: [String] = []
        for section in Section.allCases {
            let es = entries.filter { $0.section == section }.sorted { $0.key < $1.key }
            guard !es.isEmpty else { continue }
            out.append("### \(section.title)")
            out.append(contentsOf: es.map { "- \($0.key)：\($0.value)" })
        }
        return out.joined(separator: "\n")
    }
}
