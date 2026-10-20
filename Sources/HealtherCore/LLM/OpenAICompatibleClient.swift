import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for OpenAI-compatible `/chat/completions` endpoints (DeepSeek by default).
///
/// DeepSeek specifics handled here:
/// - thinking mode via `thinking: {type}` + `reasoning_effort`, reasoning returned in `reasoning_content`
/// - images only allowed in `user` messages
/// - prefix-cache stats in `prompt_cache_hit_tokens`
public struct OpenAICompatibleClient: LLMClient {
    public var baseURL: URL
    public var apiKey: String
    public var timeout: TimeInterval
    public var maxRetries: Int

    public init(baseURL: URL = URL(string: "https://api.deepseek.com")!, apiKey: String, timeout: TimeInterval = 180, maxRetries: Int = 2) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    // MARK: Encoding

    static func encode(_ message: ChatMessage, includeReasoning: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["role": .string(message.role.rawValue)]
        if message.hasImages {
            o["content"] = .array(message.parts.map { part in
                switch part {
                case .text(let t):
                    return ["type": "text", "text": .string(t)]
                case .image(let data, let mime):
                    return ["type": "image_url", "image_url": ["url": .string("data:\(mime);base64," + data.base64EncodedString())]]
                }
            })
        } else {
            o["content"] = .string(message.text)
        }
        if !message.toolCalls.isEmpty {
            o["tool_calls"] = .array(message.toolCalls.map {
                ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
            })
        }
        if let id = message.toolCallID { o["tool_call_id"] = .string(id) }
        if includeReasoning, let r = message.reasoning, !r.isEmpty { o["reasoning_content"] = .string(r) }
        return .object(o)
    }

    func body(_ req: ChatRequest, stream: Bool) -> JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(req.model),
            "messages": .array(req.messages.map { Self.encode($0, includeReasoning: req.effort != .off) }),
            "stream": .bool(stream),
        ]
        if req.effort == .off {
            o["thinking"] = ["type": "disabled"]
        } else {
            o["thinking"] = ["type": "enabled"]
            o["reasoning_effort"] = .string(req.effort.rawValue)
        }
        if stream { o["stream_options"] = ["include_usage": true] }
        if !req.tools.isEmpty {
            o["tools"] = .array(req.tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]]
            })
        }
        if let t = req.temperature { o["temperature"] = .number(t) }
        if let m = req.maxTokens { o["max_tokens"] = .number(Double(m)) }
        if req.jsonOutput { o["response_format"] = ["type": "json_object"] }
        return .object(o)
    }

    func urlRequest(_ req: ChatRequest, stream: Bool) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        var r = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { r.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        r.httpBody = Data(body(req, stream: stream).jsonString().utf8)
        return r
    }

    // MARK: Decoding

    static func usage(from v: JSONValue?) -> ChatUsage {
        var u = ChatUsage()
        guard let v else { return u }
        u.promptTokens = v["prompt_tokens"]?.intValue ?? 0
        u.completionTokens = v["completion_tokens"]?.intValue ?? 0
        u.cacheHitTokens = v["prompt_cache_hit_tokens"]?.intValue ?? v["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        u.reasoningTokens = v["completion_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
        return u
    }

    static func decodeResponse(_ data: Data) throws -> ChatResponse {
        let v = try JSONValue.parse(data)
        guard let choice = v["choices"]?.arrayValue?.first, let m = choice["message"] else {
            throw LLMError.invalidResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let calls: [ToolCall] = (m["tool_calls"]?.arrayValue ?? []).compactMap {
            guard let id = $0["id"]?.stringValue, let name = $0["function"]?["name"]?.stringValue else { return nil }
            return ToolCall(id: id, name: name, arguments: $0["function"]?["arguments"]?.stringValue ?? "{}")
        }
        let msg = ChatMessage.assistant(m["content"]?.stringValue ?? "", toolCalls: calls, reasoning: m["reasoning_content"]?.stringValue)
        return ChatResponse(message: msg, finishReason: choice["finish_reason"]?.stringValue, usage: usage(from: v["usage"]))
    }

    // MARK: LLMClient

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let req = try urlRequest(request, stream: false)
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    let err = LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
                    if Self.retryable(status), attempt < maxRetries { attempt += 1; try await backoff(attempt); continue }
                    throw err
                }
                return try Self.decodeResponse(data)
            } catch let e as URLError where attempt < maxRetries && e.code != .cancelled {
                attempt += 1
                try await backoff(attempt)
            }
        }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let req = try urlRequest(request, stream: true)
                    var attempt = 0
                    while true {
                        let accumulator = StreamAccumulator()
                        let sse = SSEConnection(request: req)
                        var received = false
                        do {
                            for try await line in sse.lines() {
                                received = true
                                for event in try accumulator.consume(line: line) { cont.yield(event) }
                            }
                            cont.yield(.completed(accumulator.finish()))
                            cont.finish()
                            return
                        } catch let LLMError.http(status, body) where !received && Self.retryable(status) && attempt < maxRetries {
                            _ = body
                            attempt += 1
                            try await backoff(attempt)
                        } catch let e as URLError where !received && attempt < maxRetries && e.code != .cancelled {
                            attempt += 1
                            try await backoff(attempt)
                        }
                    }
                } catch {
                    cont.finish(throwing: Task.isCancelled ? LLMError.cancelled : error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func retryable(_ status: Int) -> Bool { status == 429 || status >= 500 }

    private func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 700_000_000))
    }
}

/// Folds SSE chunks into deltas and a final response.
final class StreamAccumulator {
    private var text = ""
    private var reasoning = ""
    private var calls: [Int: (id: String, name: String, args: String)] = [:]
    private var finishReason: String?
    private var usage = ChatUsage()

    func consume(line: String) throws -> [ChatStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" || payload.isEmpty { return [] }
        let v = try JSONValue.parse(payload)
        if let err = v["error"] { throw LLMError.http(status: 200, body: err.jsonString()) }
        if let u = v["usage"], !u.isNull { usage = OpenAICompatibleClient.usage(from: u) }
        guard let choice = v["choices"]?.arrayValue?.first else { return [] }
        if let f = choice["finish_reason"]?.stringValue { finishReason = f }
        guard let delta = choice["delta"] else { return [] }
        var events: [ChatStreamEvent] = []
        if let r = delta["reasoning_content"]?.stringValue, !r.isEmpty {
            reasoning += r
            events.append(.reasoningDelta(r))
        }
        if let t = delta["content"]?.stringValue, !t.isEmpty {
            text += t
            events.append(.textDelta(t))
        }
        for tc in delta["tool_calls"]?.arrayValue ?? [] {
            let idx = tc["index"]?.intValue ?? 0
            var entry = calls[idx] ?? (id: "", name: "", args: "")
            let isNew = calls[idx] == nil
            if let id = tc["id"]?.stringValue, !id.isEmpty { entry.id = id }
            if let n = tc["function"]?["name"]?.stringValue, !n.isEmpty { entry.name += n }
            if let a = tc["function"]?["arguments"]?.stringValue { entry.args += a }
            calls[idx] = entry
            if isNew, !entry.name.isEmpty { events.append(.toolCallStarted(index: idx, name: entry.name)) }
        }
        return events
    }

    func finish() -> ChatResponse {
        let toolCalls = calls.keys.sorted().map { i -> ToolCall in
            let c = calls[i]!
            return ToolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, arguments: c.args.isEmpty ? "{}" : c.args)
        }
        let msg = ChatMessage.assistant(text, toolCalls: toolCalls, reasoning: reasoning.isEmpty ? nil : reasoning)
        return ChatResponse(message: msg, finishReason: finishReason, usage: usage)
    }
}
