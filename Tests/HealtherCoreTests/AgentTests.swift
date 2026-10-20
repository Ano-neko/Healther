import Foundation
import Testing
@testable import HealtherCore

@Suite struct AgentLoopTests {
    @Test func mealDraftConfirmFlow() async throws {
        let llm = ScriptedLLM([
            .assistant("", toolCalls: [toolCall("search_food", ["queries": ["白饭", "番茄炒蛋"]], id: "a")]),
            .assistant("", toolCalls: [toolCall("draft_meal", [
                "meal_type": "lunch",
                "items": [
                    ["name": "米饭", "grams": 200, "food_id": "tw:rice"],
                    ["name": "番茄炒蛋", "grams": 150, "food_id": "tw:egg"],
                    ["name": "炒菜油", "grams": 10, "per100g": ["kcal": 900, "protein": 0, "fat": 100, "carbs": 0]],
                ],
            ], id: "b")]),
            .assistant("大约 636 kcal，对吗？"),
        ])
        let s = try makeServices(llm)
        let agent = HealtherAgent(services: s)
        var meals: [Meal] = []
        for try await e in agent.send(UserInput(text: "午饭米饭+番茄炒蛋")) {
            if case .mealUpdated(let m) = e { meals.append(m) }
        }
        let draft = try #require(meals.last)
        #expect(draft.status == .draft)
        #expect(Int(draft.totals.kcal.rounded()) == 366 + 180 + 90)
        #expect(draft.items[2].source == .estimate)
        #expect(draft.items[2].confidence == .low)

        // The second request must carry the first tool result, paired to its call id.
        let second = llm.requests[1].messages
        #expect(second.contains { $0.role == .tool && $0.toolCallID == "a" })
        // Live state sits before the user message; identity is the first system message.
        #expect(second[0].text.contains("你是「小禾」"))
        #expect(second.firstIndex { $0.text.hasPrefix("## 此刻") }! < second.lastIndex { $0.role == .user }!)

        // Confirm in a second turn → personal library learns the foods.
        llm.enqueue([
            .assistant("", toolCalls: [toolCall("confirm_meal", ["draft_id": .string(draft.shortID)], id: "c")]),
            .assistant("记好了"),
        ])
        for try await _ in agent.send(UserInput(text: "对")) {}
        #expect(try s.meals.get(draft.id)?.status == .confirmed)
        let learned = try await s.personalFoods.search("番茄炒蛋", limit: 3)
        #expect(learned.first?.typicalGrams == 150)
        // And search now ranks the personal entry first.
        let results = await s.foodSearch.search(queries: ["番茄炒蛋"])
        #expect(results.first?.source == .personal)
    }

    @Test func failedTurnIsRolledBackBeforeAnyAnswer() async throws {
        let llm = ScriptedLLM([])  // first call throws
        let s = try makeServices(llm)
        let agent = HealtherAgent(services: s)
        await #expect(throws: TurnNotSent.self) {
            for try await _ in agent.send(UserInput(text: "晚上好")) {}
        }
        #expect(try s.conversation.history(limit: 10).isEmpty)

        // Once the model has answered, a later failure keeps the turn.
        llm.enqueue([.assistant("", toolCalls: [toolCall("get_meals", [:], id: "x")])])
        await #expect(throws: LLMError.self) {
            for try await _ in agent.send(UserInput(text: "今天吃了啥")) {}
        }
        #expect(try s.conversation.history(limit: 10).first?.content == "今天吃了啥")
    }

    @Test func badToolArgumentsBecomeErrorsNotCrashes() async throws {
        let llm = ScriptedLLM([
            .assistant("", toolCalls: [ToolCall(id: "x", name: "draft_meal", arguments: "{not json")]),
            .assistant("", toolCalls: [toolCall("nonexistent_tool", [:], id: "y")]),
            .assistant("抱歉，出了点问题"),
        ])
        let s = try makeServices(llm)
        var errors = 0
        for try await e in HealtherAgent(services: s).send(UserInput(text: "记一下")) {
            if case .toolFinished(_, _, true) = e { errors += 1 }
        }
        #expect(errors == 2)
        #expect(llm.requests.count == 3)
    }

    @Test func compactionFoldsOldHistoryIntoSummary() async throws {
        let llm = ScriptedLLM([
            .assistant(#"{"summary":"TA 最近在准备考试，压力大。","memories":[{"content":"在准备 CPA 考试","kind":"event","importance":4,"tags":["考试"],"replaces":null}],"profile":[{"section":"basics","key":"称呼","value":"阿泽"}]}"#),
        ])
        let s = try makeServices(llm)
        for i in 0..<6 {
            try s.conversation.append(turnID: "t\(i)", role: .user, content: "第\(i)条消息")
            try s.conversation.append(turnID: "t\(i)", role: .assistant, content: "回复\(i)")
        }
        let did = try await MemoryCurator(s: s).compactIfNeeded(force: true)
        #expect(did)
        #expect(s.conversation.rollingSummary == "TA 最近在准备考试，压力大。")
        let remaining = try s.conversation.uncompacted()
        #expect(remaining.first?.role == .user)
        #expect(remaining.count == 2)
        #expect(try s.memories.recall("考试").count == 1)
        #expect(s.profile.value(.basics, "称呼") == "阿泽")
        // The compacted turns now appear only through the summary in the stable prefix.
        let prefix = try ContextAssembler(s: s).stablePrefix(now: Date())
        #expect(prefix.contains("前情提要") && prefix.contains("准备考试"))
    }
}
