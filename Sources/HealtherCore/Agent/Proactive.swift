import Foundation

/// Messages she sends on her own: a hello after setup, a greeting when the watch says you woke up,
/// check-ins around meal times, and the occasional "just because" message.
///
/// Wake and hello are written and delivered on the spot. Meal and random messages are written
/// ahead for the rest of the day (the app schedules them as local notifications) and land in the
/// conversation once their time has passed.
public enum ProactiveKind: String, Codable, Sendable, CaseIterable {
    case hello, wake, breakfast, lunch, dinner, random

    var mealType: MealType? {
        switch self {
        case .breakfast: return .breakfast
        case .lunch: return .lunch
        case .dinner: return .dinner
        default: return nil
        }
    }
}

public struct ProactiveMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: ProactiveKind
    public var fireAt: Date
    public var text: String
}

public struct ProactiveSettings: Codable, Sendable, Equatable {
    public var wake = true
    public var meals = true
    public var random = true
    public var breakfast = "08:30"
    public var lunch = "12:00"
    public var dinner = "18:30"
    public var randomFrom = "10:00"
    public var randomTo = "21:30"

    public init() {}

    /// Missing keys keep their defaults, so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProactiveSettings()
        wake = try c.decodeIfPresent(Bool.self, forKey: .wake) ?? d.wake
        meals = try c.decodeIfPresent(Bool.self, forKey: .meals) ?? d.meals
        random = try c.decodeIfPresent(Bool.self, forKey: .random) ?? d.random
        breakfast = try c.decodeIfPresent(String.self, forKey: .breakfast) ?? d.breakfast
        lunch = try c.decodeIfPresent(String.self, forKey: .lunch) ?? d.lunch
        dinner = try c.decodeIfPresent(String.self, forKey: .dinner) ?? d.dinner
        randomFrom = try c.decodeIfPresent(String.self, forKey: .randomFrom) ?? d.randomFrom
        randomTo = try c.decodeIfPresent(String.self, forKey: .randomTo) ?? d.randomTo
    }

    public var anyEnabled: Bool { wake || meals || random }
}

public struct ProactiveStore: Sendable {
    let kv: KeyValueStore

    public init(kv: KeyValueStore) { self.kv = kv }

    public var settings: ProactiveSettings {
        kv.get("proactive.settings").flatMap { try? JSONDecoder().decode(ProactiveSettings.self, from: Data($0.utf8)) } ?? ProactiveSettings()
    }

    public func setSettings(_ s: ProactiveSettings) throws {
        try kv.set("proactive.settings", String(decoding: try JSONEncoder().encode(s), as: UTF8.self))
    }

    /// Written but not yet delivered, oldest first.
    public var queue: [ProactiveMessage] {
        kv.get("proactive.queue").flatMap { try? JSONDecoder().decode([ProactiveMessage].self, from: Data($0.utf8)) } ?? []
    }

    func setQueue(_ q: [ProactiveMessage]) throws {
        let sorted = q.sorted { $0.fireAt < $1.fireAt }
        try kv.set("proactive.queue", sorted.isEmpty ? nil : String(decoding: try JSONEncoder().encode(sorted), as: UTF8.self))
    }

    var plannedDay: String? { kv.get("proactive.planned_day") }
    var lastWakeDay: String? { kv.get("proactive.last_wake_day") }
}

/// Picks today's remaining slots. Deterministic per day so replanning doesn't reshuffle the random time.
enum ProactivePlanner {
    static func slots(on now: Date, settings: ProactiveSettings, clock: DayClock) -> [(kind: ProactiveKind, at: Date)] {
        let day = clock.startOfDay(now)
        func at(_ hhmm: String) -> Date? { clock.parse(hhmm, relativeTo: day) }
        var out: [(ProactiveKind, Date)] = []
        if settings.meals {
            for (kind, t) in [(ProactiveKind.breakfast, settings.breakfast), (.lunch, settings.lunch), (.dinner, settings.dinner)] {
                if let d = at(t) { out.append((kind, d)) }
            }
        }
        if settings.random, let from = at(settings.randomFrom), let to = at(settings.randomTo), to > from {
            var rng = SeededRandom(seed: clock.dayKey(now))
            let meals = out.map(\.1)
            // A few tries to land at least 45 minutes away from any meal check-in.
            for _ in 0..<8 {
                let d = from.addingTimeInterval(rng.nextUnit() * to.timeIntervalSince(from))
                if meals.allSatisfy({ abs($0.timeIntervalSince(d)) >= 45 * 60 }) {
                    out.append((.random, d))
                    break
                }
            }
        }
        // Only what is still ahead (with a little slack so we don't schedule into the past).
        return out.filter { $0.1 > now.addingTimeInterval(120) }.sorted { $0.1 < $1.1 }
    }
}

struct SeededRandom {
    var state: UInt64

    init(seed: String) {
        state = seed.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    /// SplitMix64 → [0, 1).
    mutating func nextUnit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

extension HealtherAgent {
    /// First words after setup. Delivered immediately; returns the saved message.
    public func sayHello(now: Date = Date()) async throws -> ConversationStore.Message? {
        let written = try await compose([(.hello, now)], now: now, context: nil)
        guard let m = written.first else { return nil }
        return try deliver(m)
    }

    /// Call when sleep data arrives. Greets once per morning, only right after a night's sleep ended.
    /// Returns the delivered message (for a notification), or nil when there is nothing to say.
    public func greetIfJustWokeUp(now: Date = Date()) async throws -> ConversationStore.Message? {
        let s = services
        let p = s.proactive
        guard p.settings.wake else { return nil }
        let today = s.clock.dayKey(now)
        guard p.lastWakeDay != today,
              let sleep = try await s.health.dailySummary(for: now).sleep,
              sleep.end <= now, now.timeIntervalSince(sleep.end) < 4 * 3600,
              (3...14).contains(s.clock.hour(sleep.end)) else { return nil }
        // Already chatting this morning? Then a "good morning" out of nowhere would be odd.
        if let last = try s.conversation.history(limit: 1).last, last.createdAt > sleep.end {
            try s.kv.set("proactive.last_wake_day", today)
            return nil
        }
        var note = "TA 的手表刚同步了昨晚的睡眠：\(s.clock.timeString(sleep.start)) → \(s.clock.timeString(sleep.end))，睡着 \(fmt(sleep.asleepHours, 1)) 小时"
        if let d = sleep.deepHours, let r = sleep.remHours { note += "（深睡 \(fmt(d, 1))h，REM \(fmt(r, 1))h）" }
        let written = try await compose([(.wake, now)], now: now, context: note)
        try s.kv.set("proactive.last_wake_day", today)
        guard let m = written.first else { return nil }
        return try deliver(m)
    }

    /// Writes the rest of today's check-ins once per day. Returns the new queue entries to schedule.
    public func planDayIfNeeded(now: Date = Date()) async throws -> [ProactiveMessage] {
        let s = services
        let p = s.proactive
        let today = s.clock.dayKey(now)
        guard p.plannedDay != today else { return [] }
        let slots = ProactivePlanner.slots(on: now, settings: p.settings, clock: s.clock)
        let written = slots.isEmpty ? [] : try await compose(slots, now: now, context: nil)
        // Anything left from earlier days is stale; keep only what is still ahead.
        try p.setQueue(p.queue.filter { $0.fireAt > now && s.clock.dayKey($0.fireAt) == today } + written)
        try s.kv.set("proactive.planned_day", today)
        return written
    }

    /// Moves check-ins whose time has come into the conversation.
    @discardableResult
    public func deliverDue(now: Date = Date()) throws -> [ConversationStore.Message] {
        let p = services.proactive
        let q = p.queue
        let due = q.filter { $0.fireAt <= now }
        guard !due.isEmpty else { return [] }
        try p.setQueue(q.filter { $0.fireAt > now })
        return try due.map(deliver)
    }

    /// Drops meal check-ins that became pointless because that meal is already logged.
    /// Returns the dropped ids so the app can withdraw their notifications.
    public func dropAnsweredCheckIns(now: Date = Date()) throws -> [String] {
        let s = services
        let p = s.proactive
        let logged = Set(try s.meals.meals(from: s.clock.startOfDay(now), to: s.clock.endOfDay(now)).map(\.type))
        let q = p.queue
        let dropped = q.filter { m in m.kind.mealType.map { logged.contains($0) } ?? false }
        if !dropped.isEmpty { try p.setQueue(q.filter { m in !dropped.contains { $0.id == m.id } }) }
        return dropped.map(\.id)
    }

    /// Forget today's plan (after settings change) so the next call writes a fresh one.
    public func resetPlan() throws -> [String] {
        let p = services.proactive
        let ids = p.queue.map(\.id)
        try p.setQueue([])
        try services.kv.set("proactive.planned_day", nil)
        return ids
    }

    // MARK: Internals

    func deliver(_ m: ProactiveMessage) throws -> ConversationStore.Message {
        var payload = ConversationStore.Payload()
        payload.proactive = m.kind.rawValue
        return try services.conversation.append(turnID: "proactive-\(m.id)", role: .assistant, content: m.text, payload: payload, at: m.fireAt)
    }

    /// One model call writes all requested messages, in character, with the full context she normally has.
    func compose(_ slots: [(kind: ProactiveKind, at: Date)], now: Date, context: String?) async throws -> [ProactiveMessage] {
        let s = services
        let a = assembler
        var messages: [ChatMessage] = [.system(try a.stablePrefix(now: now))]
        messages += a.historyMessages(try s.conversation.uncompacted(), currentTurnID: "")
        messages.append(.system(await a.liveState(now: now, userText: "")))
        messages.append(.system(Self.composeInstruction(slots, now: now, context: context, knowsName: a.knowsName, clock: s.clock)))

        let req = ChatRequest(model: s.config.models.chatModel, messages: messages, effort: .off, temperature: 1.0, jsonOutput: true)
        let r = try await s.llm.complete(req)
        s.addUsage(r.usage)
        let json = try MemoryCurator.parseJSON(r.message.text)
        var out: [ProactiveMessage] = []
        for item in json["messages"]?.arrayValue ?? [] {
            guard item["skip"]?.boolValue != true,
                  let slot = item["slot"]?.stringValue, let kind = ProactiveKind(rawValue: slot),
                  let at = slots.first(where: { $0.kind == kind })?.at,
                  let text = item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            out.append(ProactiveMessage(id: UUID().uuidString.lowercased(), kind: kind, fireAt: at, text: text))
        }
        return out
    }

    static func composeInstruction(_ slots: [(kind: ProactiveKind, at: Date)], now: Date, context: String?, knowsName: Bool, clock: DayClock) -> String {
        func brief(_ k: ProactiveKind) -> String {
            switch k {
            case .hello:
                return knowsName
                    ? "TA 刚把 App 重新设置好。打个招呼，让 TA 感觉到是你回来了。"
                    : "TA 刚装好 App，第一次见到你。用你自己的方式做个自我介绍，问 TA 想让你怎么称呼 TA。别列功能清单。"
            case .wake:
                return "TA 刚醒。打个招呼；睡眠里有值得说的就挑一件说（睡得好也可以夸），然后问问今天的打算或状态。"
            case .breakfast, .lunch, .dinner:
                return "饭点。问问 TA 吃了没、吃的什么，可以顺口说拍给你看看。别像打卡提醒；如果你知道 TA 这顿通常不吃，就换个话题或者 skip。"
            case .random:
                return "没什么特别的事，就是想找 TA 说说话：可以是你自己正在想的事、你的兴趣、对 TA 近况的好奇、之前没聊完的话头。不一定和健康有关。"
            }
        }
        let lines = slots.map { "- slot=\($0.kind.rawValue)，\(clock.timeString($0.at)) 发出：\(brief($0.kind))" }
        return """
        ## 现在由你主动找 TA（这不是在回复 TA）
        现在是 \(clock.stamp(now))。\(context.map { $0 + "。" } ?? "")请用你自己的身份和性格，写下面这些时间点要主动发给 TA 的消息：
        \(lines.joined(separator: "\n"))

        要求：
        - 每条 1–2 句，最多两段（空行分隔），像你随手发的消息，不像闹钟或系统通知。
        - 有你自己的主体性：可以从你自己的状态、兴趣、在想的事切入；不要每条都围着健康数据转。
        - 只用「此刻」和记忆里确实有的信息，不编造 TA 的数据或经历。
        - 写好的消息会到点才发出，所以除了起床问候，不要写只在此刻成立的细节（比如“刚刚看到你……”）。
        - 多条之间开头和句式不要重复。
        - 颜文字最多一个，不是每条都要。
        只输出 JSON：{"messages":[{"slot":"...","text":"...","skip":false}]}。不想发的那条 skip=true，text 留空。
        """
    }
}
