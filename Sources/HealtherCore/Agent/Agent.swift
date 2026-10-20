import Foundation

public struct UserInput: Sendable {
    public struct Image: Sendable {
        public var data: Data
        public var mimeType: String
        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public var text: String
    public var images: [Image]

    public init(text: String, images: [Image] = []) {
        self.text = text
        self.images = images
    }
}

/// A turn failed before the model answered. The user message was removed again.
public struct TurnNotSent: Error, CustomStringConvertible {
    public let underlying: Error
    public var description: String { "\(underlying)" }
}

/// The conversation loop. An actor so turns (and the maintenance that follows them) never overlap.
public actor HealtherAgent {
    public let services: HealtherServices
    let tools: ToolRegistry
    var assembler: ContextAssembler { ContextAssembler(s: services) }
    var curator: MemoryCurator { MemoryCurator(s: services) }

    public init(services: HealtherServices, tools: ToolRegistry = .standard()) {
        self.services = services
        self.tools = tools
    }

    public nonisolated func send(_ input: UserInput, now: @escaping @Sendable () -> Date = { Date() }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await self.runTurn(input, now: now, emit: { cont.yield($0) })
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func runTurn(_ input: UserInput, now: @Sendable () -> Date, emit: @Sendable (AgentEvent) -> Void) async throws {
        let s = services
        let turnID = UUID().uuidString
        let started = now()

        // 1. Persist the user message (+ photos to disk).
        var attachments: [ConversationStore.Attachment] = []
        if !input.images.isEmpty {
            try FileManager.default.createDirectory(at: s.attachmentsDirectory, withIntermediateDirectories: true)
            for img in input.images {
                let ext = img.mimeType.contains("png") ? "png" : img.mimeType.contains("webp") ? "webp" : "jpg"
                let name = "\(UUID().uuidString.lowercased()).\(ext)"
                try img.data.write(to: s.attachmentsDirectory.appendingPathComponent(name))
                attachments.append(.init(file: name, mimeType: img.mimeType))
            }
        }
        var payload = ConversationStore.Payload()
        payload.attachments = attachments.isEmpty ? nil : attachments
        try s.conversation.append(turnID: turnID, role: .user, content: input.text, payload: payload, at: started)

        var usage = ChatUsage()
        var answered = false
        do {
            // 2. Live state is computed once per turn so the prompt stays byte-stable across tool steps.
            let live = await assembler.liveState(now: started, userText: input.text)
            let ctx = ToolContext(services: s, now: started, turnID: turnID, attachments: attachments)

            // 3. Model ↔ tools loop.
            for step in 0..<s.config.maxToolSteps {
                try Task.checkCancellation()
                let messages = try assembler.build(now: started, currentTurnID: turnID, liveState: live)
                let lastStep = step == s.config.maxToolSteps - 1
                let req = ChatRequest(model: s.config.models.chatModel, messages: messages,
                                      tools: lastStep ? [] : tools.specs, effort: s.config.models.chatEffort)
                var response: ChatResponse?
                for try await event in s.llm.stream(req) {
                    switch event {
                    case .reasoningDelta(let r): emit(.reasoning(r))
                    case .textDelta(let t): emit(.text(t))
                    case .toolCallStarted(_, let name): emit(.toolStarted(name: name))
                    case .completed(let r): response = r
                    }
                }
                guard let response else { throw LLMError.invalidResponse("stream ended without completion") }
                usage = usage + response.usage

                var p = ConversationStore.Payload()
                p.toolCalls = response.message.toolCalls.isEmpty ? nil : response.message.toolCalls
                p.reasoning = response.message.reasoning
                p.usage = response.usage
                let saved = try s.conversation.append(turnID: turnID, role: .assistant, content: response.message.text, payload: p, at: now())
                emit(.assistantMessage(saved))
                answered = true

                guard !response.message.toolCalls.isEmpty else { break }
                for call in response.message.toolCalls {
                    try Task.checkCancellation()
                    let result = await execute(call, ctx)
                    for e in result.events { emit(e) }
                    emit(.toolFinished(name: call.name, summary: result.summary, isError: result.isError))
                    var tp = ConversationStore.Payload()
                    tp.toolCallID = call.id
                    tp.toolName = call.name
                    try s.conversation.append(turnID: turnID, role: .tool, content: result.content.jsonString(), payload: tp, at: now())
                }
            }
        } catch {
            // Nothing came back yet: take the message back so the user can resend it
            // without leaving an unanswered duplicate in the history.
            if !answered {
                try? s.conversation.deleteTurn(turnID)
                for a in attachments { try? FileManager.default.removeItem(at: s.attachmentsDirectory.appendingPathComponent(a.file)) }
                throw TurnNotSent(underlying: error)
            }
            throw error
        }

        s.addUsage(usage)
        emit(.turnFinished(usage))

        // 4. Maintenance after the reply is out: diary for finished days, then compaction.
        await maintain(now: now(), emit: emit)
    }

    func execute(_ call: ToolCall, _ ctx: ToolContext) async -> ToolResult {
        guard let tool = tools.tool(named: call.name) else { return .error("未知工具 \(call.name)") }
        let args: JSONValue
        do {
            args = try JSONValue.parse(call.arguments.isEmpty ? "{}" : call.arguments)
        } catch {
            return .error("参数不是合法 JSON：\(call.arguments.prefix(200))")
        }
        do {
            return try await tool.run(args, ctx)
        } catch {
            return .error("\(call.name) 执行失败：\(error)")
        }
    }

    public func maintain(now: Date = Date(), emit: @Sendable (AgentEvent) -> Void = { _ in }) async {
        do {
            let days = try await curator.reflectPendingDays(now: now)
            if !days.isEmpty { emit(.maintenance("写好了 \(days.joined(separator: "、")) 的日记")) }
        } catch {
            emit(.maintenance("日记生成失败：\(error)"))
        }
        do {
            if try await curator.compactIfNeeded() { emit(.maintenance("整理了较早的对话记忆")) }
        } catch {
            emit(.maintenance("记忆整理失败：\(error)"))
        }
        try? services.meals.purgeDrafts(olderThan: now.addingTimeInterval(-3 * 86_400))
    }

    // MARK: Debug / CLI hooks

    public func forceCompact() async throws -> Bool { try await curator.compactIfNeeded(force: true) }

    public func reflect(day: Date) async throws -> Bool { try await curator.reflect(day: day) }

    /// The exact prompt the next turn would see (minus the new user message).
    public func debugContext(now: Date = Date(), userText: String = "") async throws -> [ChatMessage] {
        let live = await assembler.liveState(now: now, userText: userText)
        return try assembler.build(now: now, currentTurnID: "debug", liveState: live)
    }
}
