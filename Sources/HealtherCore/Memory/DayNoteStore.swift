import Foundation

/// The headline the agent pins to a day's Today screen, e.g. "今天悠着点 / 昨晚只睡了 5 小时，午后别喝咖啡".
public struct DayNote: Codable, Sendable, Equatable {
    public var title: String
    public var detail: String
    public var updatedAt: Date
    /// A `CardFont` raw value; nil = the app's default. Kept as a string so unknown values never break decoding.
    public var font: String?

    public init(title: String, detail: String, updatedAt: Date, font: String? = nil) {
        self.title = title
        self.detail = detail
        self.updatedAt = updatedAt
        self.font = font
    }

    public static let maxTitle = 30
    public static let maxDetail = 300
}

/// Typefaces for the pinned card. Each pairs a Latin face with a Chinese one.
public enum CardFont: String, CaseIterable, Sendable {
    case system, rounded, serif, kai, hand

    public var title: String {
        switch self {
        case .system: return "默认（苹方）"
        case .rounded: return "圆体"
        case .serif: return "衬线（Times New Roman + 宋体）"
        case .kai: return "楷体"
        case .hand: return "手写（手札体）"
        }
    }

    /// For the tool schema.
    public var hint: String {
        switch self {
        case .system: return "system=默认无衬线"
        case .rounded: return "rounded=圆体，可爱轻松"
        case .serif: return "serif=英文 Times New Roman、中文宋体，文艺正式"
        case .kai: return "kai=楷体，书卷气"
        case .hand: return "hand=手写体，像便利贴"
        }
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
