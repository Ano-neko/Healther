import Foundation
@testable import HealtherCore

/// Scripted LLM: returns queued responses in order and records every request.
final class ScriptedLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ChatMessage]
    private(set) var requests: [ChatRequest] = []

    init(_ responses: [ChatMessage]) { queue = responses }

    func enqueue(_ more: [ChatMessage]) { lock.withLock { queue += more } }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        try lock.withLock {
            requests.append(request)
            guard !queue.isEmpty else { throw LLMError.invalidResponse("script exhausted") }
            var usage = ChatUsage()
            usage.promptTokens = 100
            return ChatResponse(message: queue.removeFirst(), finishReason: "stop", usage: usage)
        }
    }
}

/// Minimal in-memory food table for tests.
struct FakeFoodTable: FoodDataSource {
    let idPrefixes = ["tw"]
    let foods: [FoodCandidate] = [
        FoodCandidate(id: "tw:rice", source: .taiwanFDA, name: "白饭", per100g: Nutrients(kcal: 183, protein: 3.1, fat: 0.3, carbs: 41)),
        FoodCandidate(id: "tw:egg", source: .taiwanFDA, name: "番茄炒蛋", per100g: Nutrients(kcal: 120, protein: 6, fat: 9, carbs: 4)),
    ]

    func search(_ query: String, limit: Int) async throws -> [FoodCandidate] {
        foods.filter { SearchTokenizer.coverage(of: query, in: $0.name) > 0 }
    }

    func lookup(id: String) async throws -> FoodCandidate? { foods.first { $0.id == id } }
}

func makeServices(_ llm: any LLMClient, timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) throws -> HealtherServices {
    let db = try UserDatabase.inMemory()
    let clock = DayClock(timeZone: timeZone)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("healther-tests-\(UUID().uuidString)")
    let config = HealtherConfig(dataDirectory: dir)
    return HealtherServices(config: config, db: db, llm: llm, health: MockHealthDataSource(db: db, clock: clock),
                            foodTables: [FakeFoodTable()], clock: clock, enableOnlineFood: false)
}

func toolCall(_ name: String, _ args: JSONValue, id: String = UUID().uuidString) -> ToolCall {
    ToolCall(id: id, name: name, arguments: args.jsonString())
}
