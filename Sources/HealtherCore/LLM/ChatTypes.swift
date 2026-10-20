import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

public enum ContentPart: Sendable, Hashable {
    case text(String)
    case image(Data, mimeType: String)
}

public struct ToolCall: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Raw JSON arguments as produced by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Hashable {
    public var role: ChatRole
    public var parts: [ContentPart]
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    /// Thinking-mode reasoning. Sent back only within the turn that produced it.
    public var reasoning: String?

    public init(role: ChatRole, parts: [ContentPart], toolCalls: [ToolCall] = [], toolCallID: String? = nil, reasoning: String? = nil) {
        self.role = role
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoning = reasoning
    }

    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }

    public var hasImages: Bool {
        parts.contains { if case .image = $0 { return true } else { return false } }
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, parts: [.text(text)]) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, parts: [.text(text)]) }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = [], reasoning: String? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, parts: text.isEmpty ? [] : [.text(text)], toolCalls: toolCalls, reasoning: reasoning)
    }
    public static func tool(callID: String, content: String) -> ChatMessage {
        ChatMessage(role: .tool, parts: [.text(content)], toolCallID: callID)
    }
}

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum ReasoningEffort: String, Codable, Sendable {
    case off, low, high, max
}

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var effort: ReasoningEffort
    public var temperature: Double?
    public var maxTokens: Int?
    public var jsonOutput: Bool

    public init(model: String, messages: [ChatMessage], tools: [ToolSpec] = [], effort: ReasoningEffort = .off,
                temperature: Double? = nil, maxTokens: Int? = nil, jsonOutput: Bool = false) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.effort = effort
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.jsonOutput = jsonOutput
    }
}

public struct ChatUsage: Codable, Sendable, Hashable {
    public var promptTokens = 0
    public var completionTokens = 0
    public var cacheHitTokens = 0
    public var reasoningTokens = 0

    public init() {}

    public static func + (a: ChatUsage, b: ChatUsage) -> ChatUsage {
        var u = ChatUsage()
        u.promptTokens = a.promptTokens + b.promptTokens
        u.completionTokens = a.completionTokens + b.completionTokens
        u.cacheHitTokens = a.cacheHitTokens + b.cacheHitTokens
        u.reasoningTokens = a.reasoningTokens + b.reasoningTokens
        return u
    }
}

public struct ChatResponse: Sendable {
    public var message: ChatMessage
    public var finishReason: String?
    public var usage: ChatUsage
}

public enum ChatStreamEvent: Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    /// A tool call started streaming (name known, arguments still arriving).
    case toolCallStarted(index: Int, name: String)
    case completed(ChatResponse)
}

public enum LLMError: Error, CustomStringConvertible {
    case missingAPIKey
    case http(status: Int, body: String)
    case invalidResponse(String)
    case cancelled

    public var description: String {
        switch self {
        case .missingAPIKey: return "没有配置 API Key"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(300))"
        case .invalidResponse(let m): return "无法解析模型响应: \(m)"
        case .cancelled: return "已取消"
        }
    }
}

public protocol LLMClient: Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResponse
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

extension LLMClient {
    /// Default streaming: a single completed event. Real clients override.
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let r = try await complete(request)
                    if let reasoning = r.message.reasoning { cont.yield(.reasoningDelta(reasoning)) }
                    if !r.message.text.isEmpty { cont.yield(.textDelta(r.message.text)) }
                    cont.yield(.completed(r))
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
