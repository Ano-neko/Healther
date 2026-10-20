import Foundation
import Testing
@testable import HealtherCore

@Suite struct ProactiveTests {
    let clock = DayClock(timeZone: TimeZone(identifier: "Asia/Shanghai")!)

    @Test func plannerKeepsFutureSlotsAndSpacesTheRandomOne() throws {
        let morning = try #require(clock.parse("2026-10-20 07:00", relativeTo: Date()))
        let slots = ProactivePlanner.slots(on: morning, settings: ProactiveSettings(), clock: clock)
        #expect(slots.map(\.kind).filter { $0 != .random } == [.breakfast, .lunch, .dinner])
        let random = try #require(slots.first { $0.kind == .random })
        for meal in slots where meal.kind != .random {
            #expect(abs(meal.at.timeIntervalSince(random.at)) >= 45 * 60)
        }
        // Same day → same random time; past slots are dropped.
        let afternoon = try #require(clock.parse("2026-10-20 13:00", relativeTo: Date()))
        let later = ProactivePlanner.slots(on: afternoon, settings: ProactiveSettings(), clock: clock)
        #expect(!later.contains { $0.kind == .breakfast || $0.kind == .lunch })
        if random.at > afternoon { #expect(later.first { $0.kind == .random }?.at == random.at) }
    }

    @Test func planDeliverAndDropAnsweredCheckIns() async throws {
        let llm = ScriptedLLM([.assistant(#"""
        {"messages":[{"slot":"breakfast","text":"早饭吃了没？"},{"slot":"lunch","text":"午饭呢？"},
                     {"slot":"dinner","text":"","skip":true},{"slot":"random","text":"我刚通关了 (￣▽￣)"}]}
        """#)])
        let s = try makeServices(llm)
        var settings = ProactiveSettings()
        settings.random = true
        try s.proactive.setSettings(settings)
        let agent = HealtherAgent(services: s)
        let morning = try #require(s.clock.parse("2026-10-20 07:00", relativeTo: Date()))

        let planned = try await agent.planDayIfNeeded(now: morning)
        #expect(Set(planned.map(\.kind)) == [.breakfast, .lunch, .random])
        #expect(try await agent.planDayIfNeeded(now: morning).isEmpty)  // once per day
        #expect(llm.requests.last?.messages.last?.text.contains("slot=lunch") == true)

        // Breakfast gets logged before its check-in would matter → lunch stays, breakfast is dropped.
        try s.meals.save(Meal(status: .confirmed, type: .breakfast, eatenAt: morning, items: []))
        let dropped = try await agent.dropAnsweredCheckIns(now: morning)
        #expect(dropped.count == 1)

        let noon = try #require(s.clock.parse("2026-10-20 12:05", relativeTo: Date()))
        let delivered = try await agent.deliverDue(now: noon)
        #expect(delivered.map(\.content) == ["午饭呢？"])
        #expect(delivered.first?.payload.proactive == "lunch")

        // The model sees it as something she said on her own.
        let history = ContextAssembler(s: s).historyMessages(try s.conversation.uncompacted(), currentTurnID: "")
        #expect(history.first?.role == .system)
        #expect(history.first?.text.contains("你主动给 TA 发了") == true)
        #expect(history.last?.role == .assistant)
    }

    @Test func helloAsksForNameWhenUnknown() {
        let text = HealtherAgent.composeInstruction([(.hello, Date())], now: Date(), context: nil, knowsName: false, clock: clock)
        #expect(text.contains("怎么称呼"))
        #expect(text.contains("JSON"))
    }

    @Test func personaIsEditableAndFallsBack() throws {
        let s = try makeServices(ScriptedLLM([]))
        #expect(s.persona.custom == nil)
        try s.persona.save(PersonaProfile(identity: "骇客", personality: ""))
        #expect(s.persona.current.identity == "骇客")
        #expect(s.persona.current.personality == PersonaProfile.default.personality)
        #expect(try ContextAssembler(s: s).stablePrefix(now: Date()).contains("骇客"))
        try s.persona.save(nil)
        #expect(s.persona.custom == nil)
    }

    @Test func exportCoversProfileMemoriesAndPersona() throws {
        let s = try makeServices(ScriptedLLM([]))
        try s.profile.set(.basics, "称呼", "AEther")
        _ = try s.memories.remember("工作日一般不吃晚饭", kind: .preference)
        let md = try MemoryExporter.markdown(s)
        #expect(md.contains("**称呼**：AEther"))
        #expect(md.contains("工作日一般不吃晚饭"))
        #expect(md.contains("### 身份核心"))
    }
}
