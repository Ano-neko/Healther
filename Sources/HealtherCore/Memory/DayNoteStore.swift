import Foundation

/// The headline the agent pins to a day's Today screen, e.g. "今天悠着点 / 昨晚只睡了 5 小时，午后别喝咖啡".
public struct DayNote: Codable, Sendable, Equatable {
    public var title: String
    public var detail: String
    public var updatedAt: Date

    public init(title: String, detail: String, updatedAt: Date) {
        self.title = title
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

public struct DayNoteStore: Sendable {
    let kv: KeyValueStore

    public init(kv: KeyValueStore) { self.kv = kv }

    public func note(for dayKey: String) -> DayNote? {
        guard let raw = kv.get("daynote.\(dayKey)") else { return nil }
        return try? JSONDecoder().decode(DayNote.self, from: Data(raw.utf8))
    }

    /// nil clears the note.
    public func set(_ note: DayNote?, for dayKey: String) throws {
        let raw = try note.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try kv.set("daynote.\(dayKey)", raw)
    }
}
