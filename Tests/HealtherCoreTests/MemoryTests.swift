import Foundation
import Testing
@testable import HealtherCore

@Suite struct MemoryStoreTests {
    @Test func recallFindsChineseByBigram() throws {
        let store = MemoryStore(db: try UserDatabase.inMemory())
        try store.remember("每天早上喝两杯美式咖啡", kind: .preference)
        try store.remember("在准备 CPA 考试，晚上常学到 1 点", kind: .event, importance: 4)
        try store.remember("养了一只橘猫叫年糕", kind: .fact)

        let hits = try store.recall("咖啡")
        #expect(hits.first?.memory.content.contains("咖啡") == true)
        #expect(try store.recall("考试压力").first?.memory.content.contains("CPA") == true)
        #expect(try store.recall("吉他").isEmpty)
    }

    @Test func supersededMemoriesDropOutOfRecall() throws {
        let store = MemoryStore(db: try UserDatabase.inMemory())
        let old = try store.remember("每天早上喝两杯咖啡", kind: .preference)
        let new = try store.remember("已经戒咖啡了，改喝茶", kind: .preference, replaces: old.id)
        let ids = try store.recall("咖啡").map(\.memory.id)
        #expect(ids == [new.id])
        #expect(try store.get(old.id)?.supersededBy == new.id)
    }

    @Test func nearDuplicatesAreMerged() throws {
        let store = MemoryStore(db: try UserDatabase.inMemory())
        let a = try store.remember("对花生过敏", kind: .health, importance: 3)
        let b = try store.remember("对花生过敏。", kind: .health, importance: 5)
        #expect(a.id == b.id)
        #expect(b.importance == 5)
        #expect(store.count == 1)
    }

    @Test func forgetRemovesFromRecall() throws {
        let store = MemoryStore(db: try UserDatabase.inMemory())
        let m = try store.remember("膝盖有旧伤，不能跑太久", kind: .health)
        try store.forget(m.id)
        #expect(try store.recall("膝盖").isEmpty)
    }
}

@Suite struct ProfileStoreTests {
    @Test func renderGroupsBySectionAndDeletes() throws {
        let p = ProfileStore(db: try UserDatabase.inMemory())
        try p.set(.basics, "称呼", "阿泽")
        try p.set(.health, "过敏", "花生")
        try p.set(.basics, "身高", "175cm")
        let text = try p.render()
        #expect(text.contains("### 基本信息\n- 称呼：阿泽\n- 身高：175cm"))
        #expect(text.contains("### 身体与健康状况\n- 过敏：花生"))
        try p.set(.health, "过敏", nil)
        #expect(!(try p.render()).contains("过敏"))
    }
}

@Suite struct ContextAssemblerTests {
    @Test func historyStartsAtUserAndClosesDanglingToolCalls() throws {
        let s = try makeServices(ScriptedLLM([]))
        var p = ConversationStore.Payload()
        p.toolCalls = [ToolCall(id: "c1", name: "recall", arguments: "{}"), ToolCall(id: "c2", name: "recall", arguments: "{}")]
        // An orphan tool row before any user message must be skipped.
        var orphan = ConversationStore.Payload()
        orphan.toolCallID = "zz"
        try s.conversation.append(turnID: "t0", role: .tool, content: "{}", payload: orphan)
        try s.conversation.append(turnID: "t1", role: .user, content: "hi")
        try s.conversation.append(turnID: "t1", role: .assistant, content: "", payload: p)
        var r1 = ConversationStore.Payload()
        r1.toolCallID = "c1"
        try s.conversation.append(turnID: "t1", role: .tool, content: "{}", payload: r1)
        // c2's result is missing (crash) → assembler must synthesize it.
        try s.conversation.append(turnID: "t2", role: .user, content: "again")

        let msgs = ContextAssembler(s: s).historyMessages(try s.conversation.uncompacted(), currentTurnID: "t2")
        #expect(msgs.map(\.role) == [.user, .assistant, .tool, .tool, .user])
        #expect(msgs[3].toolCallID == "c2")
    }

    @Test func liveStateGoesRightBeforeCurrentUserMessage() throws {
        let s = try makeServices(ScriptedLLM([]))
        try s.conversation.append(turnID: "t1", role: .user, content: "早")
        try s.conversation.append(turnID: "t1", role: .assistant, content: "早呀")
        try s.conversation.append(turnID: "t2", role: .user, content: "吃什么")
        let msgs = try ContextAssembler(s: s).build(now: Date(), currentTurnID: "t2", liveState: "## 此刻")
        #expect(msgs.map(\.role) == [.system, .user, .assistant, .system, .user])
        #expect(msgs[0].text.contains("你是「小禾」"))
        #expect(msgs[3].text == "## 此刻")
    }

    @Test func liveStateAsksForNameUntilProfileHasOne() async throws {
        let s = try makeServices(ScriptedLLM([]))
        let a = ContextAssembler(s: s)
        #expect(await a.liveState(now: Date(), userText: "晚上好").contains("你们还不认识"))
        try s.profile.set(.basics, "称呼", "阿泽")
        #expect(await !a.liveState(now: Date(), userText: "晚上好").contains("你们还不认识"))
    }

    @Test func todayCardIsStoredAndShownInLiveState() async throws {
        let s = try makeServices(ScriptedLLM([]))
        let now = Date()
        let ctx = ToolContext(services: s, now: now, turnID: "t", attachments: [])
        _ = try await SetTodayCardTool().run(["title": "今天悠着点", "detail": "昨晚睡得少，早点睡"], ctx)
        #expect(s.dayNotes.note(for: s.clock.dayKey(now))?.title == "今天悠着点")
        #expect(await ContextAssembler(s: s).liveState(now: now, userText: "").contains("「今天悠着点」"))
        _ = try await SetTodayCardTool().run(["title": ""], ctx)
        #expect(s.dayNotes.note(for: s.clock.dayKey(now)) == nil)
    }

    @Test func oldPhotosBecomePlaceholders() throws {
        let s = try makeServices(ScriptedLLM([]))
        var p = ConversationStore.Payload()
        p.attachments = [.init(file: "missing.jpg", mimeType: "image/jpeg")]
        try s.conversation.append(turnID: "t1", role: .user, content: "午饭", payload: p)
        try s.conversation.append(turnID: "t2", role: .user, content: "然后呢")
        let msgs = ContextAssembler(s: s).historyMessages(try s.conversation.uncompacted(), currentTurnID: "t2")
        #expect(msgs[0].text.hasSuffix("午饭（附了 1 张照片）"))
        #expect(!msgs[0].hasImages)
    }
}
