import Foundation

public struct ToolContext: Sendable {
    public let services: HealtherServices
    public let now: Date
    public let turnID: String
    /// Photos attached to the current user message (file names under attachments/).
    public let attachments: [ConversationStore.Attachment]

    public var clock: DayClock { services.clock }
}

public struct ToolResult: Sendable {
    public var content: JSONValue
    public var events: [AgentEvent]
    /// One-line human summary for the UI ("查询了 3 种食物").
    public var summary: String
    public var isError: Bool

    public init(_ content: JSONValue, summary: String, events: [AgentEvent] = [], isError: Bool = false) {
        self.content = content
        self.summary = summary
        self.events = events
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(["error": .string(message)], summary: message, isError: true)
    }
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult
}

extension AgentTool {
    public var spec: ToolSpec { ToolSpec(name: name, description: description, parameters: parameters) }
}

public struct ToolRegistry: Sendable {
    public private(set) var tools: [any AgentTool]

    public init(_ tools: [any AgentTool]) { self.tools = tools }

    public var specs: [ToolSpec] { tools.map(\.spec) }

    public func tool(named name: String) -> (any AgentTool)? { tools.first { $0.name == name } }

    public static func standard() -> ToolRegistry {
        ToolRegistry(HealthTools.all + FoodTools.all + WellbeingTools.all + MemoryTools.all)
    }
}

public enum AgentEvent: Sendable {
    case reasoning(String)
    case text(String)
    case toolStarted(name: String)
    case toolFinished(name: String, summary: String, isError: Bool)
    case mealUpdated(Meal)
    case memoryChanged(String)
    case assistantMessage(ConversationStore.Message)
    case turnFinished(ChatUsage)
    case maintenance(String)
}
