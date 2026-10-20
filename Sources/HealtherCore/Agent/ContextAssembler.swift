import Foundation

/// Builds the prompt for every model call, rebuilt from the database each time:
///
///     [system]  L0 persona + L1 profile + recent diary + rolling summary   ← stable, prefix-cached
///     [user/assistant/tool ...]  uncompacted history (L4 tail)
///     [system]  「此刻」: L2 live state + auto-recalled L3 memories          ← per turn
///     [user]    current message (+ photos)
///     [assistant/tool ...]  this turn's tool loop so far
///
/// Identity and the user's state never live in the history, so no amount of
/// chit-chat or compaction can make the agent forget what it is for.
struct ContextAssembler {
    let s: HealtherServices

    var clock: DayClock { s.clock }

    // MARK: Stable prefix

    func stablePrefix(now: Date) throws -> String {
        var parts = [Persona.systemPrompt(name: s.config.assistantName, profile: s.persona.current)]
        parts.append("## 关于 TA（档案）\n" + (try s.profile.render()))
        parts.append("## TA 的身体资料\n" + renderBody(now: now))
        let episodes = try s.episodes.recent(5, before: clock.dayKey(now))
        if !episodes.isEmpty {
            let lines = episodes.reversed().map { e -> String in
                let date = clock.date(fromDayKey: e.day).map { "\(e.day.suffix(5)) \(clock.weekdayName($0))" } ?? e.day
                return "- \(date)：\(e.summary)" + (e.mood.map { "（状态：\($0)）" } ?? "")
            }
            parts.append("## 最近的日子（你写的日记）\n" + lines.joined(separator: "\n"))
        }
        if let summary = s.conversation.rollingSummary, !summary.isEmpty {
            parts.append("## 前情提要（更早对话的摘要）\n" + summary)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Height / age / sex: typed in by the user (settings or chat), else from Apple Health.
    func renderBody(now: Date) -> String {
        let b = s.body.current, manual = s.body.manual
        var lines: [String] = []
        func src(_ isManual: Bool) -> String { isManual ? "" : "（来自 Apple 健康）" }
        if let h = b.heightCm { lines.append("- 身高 \(fmt(h))cm" + src(manual.heightCm != nil)) }
        if let y = b.birthYear, let age = b.age(now: now, calendar: clock.calendar) {
            lines.append("- 出生 \(y) 年（今年 \(age) 岁）" + src(manual.birthYear != nil))
        }
        if let sex = b.sex.flatMap(BodyProfile.Sex.init(rawValue:)) { lines.append("- 性别 \(sex.title)" + src(manual.sex != nil)) }
        let missing = [b.heightCm == nil ? "身高" : nil, b.birthYear == nil ? "年龄" : nil].compactMap { $0 }
        if !missing.isEmpty {
            lines.append("- 还不知道\(missing.joined(separator: "、"))。合适时顺口问，TA 说了就用 update_body_profile 记（TA 也能在设置「我的身体」里填）")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Live state

    func liveState(now: Date, userText: String) async -> String {
        await s.syncBodyFromHealth()
        var lines: [String] = []
        let today = clock.startOfDay(now), tomorrow = clock.endOfDay(now)
        lines.append("- 现在：\(clock.stamp(now)) \(clock.weekdayName(now))（\(clock.utcOffsetString(now))）")
        if s.health.isMock { lines.append("- 注意：当前是开发环境的模拟健康数据") }
        if !knowsName {
            lines.append("- 你们还不认识：档案里还没有 TA 的称呼。先简单介绍自己，问 TA 希望你怎么称呼 TA，拿到就 update_profile（basics / 称呼）。之后在聊天中自然地了解身高体重、目标、作息等，一次最多问一件，不要问卷式盘问。")
        }

        let goals = (try? s.wellbeing.goals()) ?? []
        func goal(_ k: WellbeingStore.GoalKind) -> String {
            goals.first { $0.kind == k }.map { " / 目标 \(fmt($0.target))" } ?? ""
        }

        if let h = try? await s.healthSummary(for: now) {
            if let sl = h.sleep {
                var t = "- 昨晚睡眠：\(clock.timeString(sl.start)) → \(clock.timeString(sl.end))，睡着 \(fmt(sl.asleepHours, 1))h"
                if let d = sl.deepHours, let r = sl.remHours { t += "（深睡 \(fmt(d, 1))h，REM \(fmt(r, 1))h）" }
                lines.append(t + goal(.sleepHours))
            } else {
                lines.append("- 昨晚睡眠：无记录")
            }
            var act: [String] = []
            if let v = h.steps { act.append("步数 \(fmt(v))" + goal(.steps)) }
            if let v = h.activeEnergy { act.append("活动能量 \(fmt(v)) kcal") }
            if let v = h.extra[.basalEnergy] { act.append("静息能量 \(fmt(v)) kcal") }
            if let v = h.exerciseMinutes { act.append("锻炼 \(fmt(v)) 分钟" + goal(.exerciseMinutes)) }
            if !h.workouts.isEmpty { act.append("运动：" + h.workouts.map { "\($0.type) \(fmt($0.minutes))分钟" }.joined(separator: "、")) }
            if !act.isEmpty { lines.append("- 今日活动：" + act.joined(separator: "，")) }
            var body: [String] = []
            // The watch computes these later in the day; until then yesterday's is the useful number.
            if let v = await recent(h.restingHeartRate, .restingHeartRate, now: now) { body.append("静息心率 \(v)") }
            if let v = await recent(h.hrv, .heartRateVariability, now: now) { body.append("HRV \(v)ms") }
            if let v = h.extra[.bloodOxygen] { body.append("血氧 \(fmt(v))%") }
            if let v = h.bodyMass {
                body.append("体重 \(fmt(v, 1))kg" + (h.bodyMassDate.map { "（\(clock.dayKey($0).suffix(5))）" } ?? "") + goal(.weightKg))
            }
            if !body.isEmpty { lines.append("- 身体：" + body.joined(separator: "，")) }
            if !h.events.isEmpty { lines.append("- 今日健康记录：" + h.events.joined(separator: "；")) }
        }

        if let n = try? s.meals.totals(from: today, to: tomorrow) {
            lines.append("- 今日饮食（已确认）：\(fmt(n.kcal)) kcal\(goal(.dailyKcal))；蛋白质 \(fmt(n.protein))g\(goal(.proteinG))，脂肪 \(fmt(n.fat))g，碳水 \(fmt(n.carbs))g")
        }
        if let meals = try? s.meals.meals(from: today, to: tomorrow), !meals.isEmpty {
            lines.append("  已记：" + meals.map { "\($0.type.displayName) \(clock.timeString($0.eatenAt)) \(fmt($0.totals.kcal))kcal" }.joined(separator: "；"))
        }
        if let drafts = try? s.meals.drafts(since: now.addingTimeInterval(-12 * 3600)), !drafts.isEmpty {
            lines.append("- 待确认的饮食草稿：" + drafts.map { "draft_id=\($0.shortID)（\($0.type.displayName)，\(fmt($0.totals.kcal))kcal：\($0.items.map(\.name).joined(separator: "、"))）" }.joined(separator: "；"))
        }
        if let w = try? s.wellbeing.water(from: today, to: tomorrow), w > 0 || goals.contains(where: { $0.kind == .waterML }) {
            lines.append("- 今日饮水：\(fmt(w)) ml\(goal(.waterML))")
        }
        if let moods = try? s.wellbeing.moods(from: today, to: tomorrow), !moods.isEmpty {
            lines.append("- 今日情绪记录：" + moods.map { "\(clock.timeString($0.at)) \($0.valence > 0 ? "+" : "")\($0.valence) \($0.labels.joined(separator: "/"))" }.joined(separator: "；"))
        }
        if let note = s.dayNotes.note(for: clock.dayKey(now)) {
            lines.append("- 今日卡片（你钉在「今日」页顶部的）：「\(note.title)」\(note.detail)")
        }
        let otherGoals = goals.filter { [.bedtime].contains($0.kind) }
        if !otherGoals.isEmpty {
            lines.append("- 其他目标：" + otherGoals.map { "\($0.kind.title) \(fmt($0.target, 1))\($0.kind.unit)" + ($0.note.map { "（\($0)）" } ?? "") }.joined(separator: "，"))
        }

        let recalled = autoRecall(userText, now: now)
        if !recalled.isEmpty {
            lines.append("- 可能相关的记忆（自动检索，未必都相关）：")
            lines.append(contentsOf: recalled.map { "  - [#\($0.id) \($0.kind.title) \(clock.dayKey($0.createdAt))] \($0.content)" })
        }
        return "## 此刻（你的背景感知，系统每轮更新。不要复述，用得上再提）\n" + lines.joined(separator: "\n")
    }

    /// Today's value, or the latest of the past two days marked with its date.
    func recent(_ today: Double?, _ metric: HealthMetric, now: Date) async -> String? {
        if let today { return fmt(today) }
        let values = (try? await s.dailyValues(metric, days: 3, endingAt: now)) ?? []
        guard let last = values.last(where: { $0.value != nil }), let v = last.value else { return nil }
        return "\(fmt(v))（\(clock.dayKey(last.day).suffix(5))）"
    }

    /// Whether the profile already says what to call the user.
    var knowsName: Bool {
        let basics = ((try? s.profile.all()) ?? []).filter { $0.section == .basics }
        return basics.contains { e in ["称呼", "名字", "姓名", "昵称", "名"].contains { e.key.contains($0) } && !e.value.isEmpty }
    }

    func autoRecall(_ text: String, now: Date) -> [MemoryStore.Memory] {
        guard text.count >= 2, let hits = try? s.memories.recall(text, limit: s.config.autoRecallLimit * 2, touch: false, now: now) else { return [] }
        // Keep hits that genuinely overlap the message, not just one common bigram.
        return hits.filter { SearchTokenizer.coverage(of: $0.memory.content, in: text) >= 0.15 || SearchTokenizer.coverage(of: text, in: $0.memory.content) >= 0.3 }
            .prefix(s.config.autoRecallLimit).map(\.memory)
    }

    // MARK: History

    func historyMessages(_ msgs: [ConversationStore.Message], currentTurnID: String) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var pendingCalls: [String] = []

        func closePending() {
            for id in pendingCalls { out.append(.tool(callID: id, content: #"{"error":"interrupted"}"#)) }
            pendingCalls.removeAll()
        }

        // History starts at a user message, or at a message she sent on her own.
        let start = msgs.firstIndex { $0.role == .user || $0.payload.proactive != nil } ?? msgs.endIndex
        for m in msgs[start...] {
            let isCurrent = m.turnID == currentTurnID
            switch m.role {
            case .assistant where m.payload.proactive != nil:
                closePending()
                out.append(.system("（\(clock.stamp(m.createdAt).dropFirst(5))，你主动给 TA 发了下面这条消息）"))
                out.append(.assistant(m.content))
            case .user:
                closePending()
                var parts: [ContentPart] = []
                let stamp = "[\(clock.stamp(m.createdAt).dropFirst(5))] "
                let attachments = m.payload.attachments ?? []
                if isCurrent {
                    parts.append(.text(stamp + (m.content.isEmpty ? "（发来了照片）" : m.content)))
                    for a in attachments {
                        if let data = try? Data(contentsOf: s.attachmentsDirectory.appendingPathComponent(a.file)) {
                            parts.append(.image(data, mimeType: a.mimeType))
                        }
                    }
                } else {
                    let note = attachments.isEmpty ? "" : "（附了 \(attachments.count) 张照片）"
                    parts.append(.text(stamp + m.content + note))
                }
                out.append(ChatMessage(role: .user, parts: parts))
            case .assistant:
                closePending()
                let calls = m.payload.toolCalls ?? []
                out.append(.assistant(m.content, toolCalls: calls, reasoning: isCurrent ? m.payload.reasoning : nil))
                pendingCalls = calls.map(\.id)
            case .tool:
                guard let id = m.payload.toolCallID, let i = pendingCalls.firstIndex(of: id) else { continue }
                pendingCalls.remove(at: i)
                out.append(.tool(callID: id, content: m.content))
            case .system:
                continue
            }
        }
        closePending()
        return out
    }

    // MARK: Assemble

    func build(now: Date, currentTurnID: String, liveState: String) throws -> [ChatMessage] {
        let msgs = try s.conversation.uncompacted()
        var history = historyMessages(msgs, currentTurnID: currentTurnID)
        // Insert live state right before the current turn's user message.
        let currentUserIndex = history.lastIndex { $0.role == .user } ?? history.endIndex
        history.insert(.system(liveState), at: currentUserIndex)
        return [.system(try stablePrefix(now: now))] + history
    }
}

enum TokenEstimator {
    /// Rough: DeepSeek's tokenizer is ~0.6 tokens per CJK char, ~0.3 per Latin char.
    static func estimate(_ text: String) -> Int {
        var cjk = 0, other = 0
        for u in text.unicodeScalars { if SearchTokenizer.isCJK(u) { cjk += 1 } else { other += 1 } }
        return Int(Double(cjk) * 0.65 + Double(other) * 0.3) + 4
    }

    static func estimate(_ m: ConversationStore.Message) -> Int {
        var n = estimate(m.content)
        if let calls = m.payload.toolCalls { n += calls.reduce(0) { $0 + estimate($1.arguments) + 8 } }
        n += (m.payload.attachments?.count ?? 0) * 20
        return n
    }
}

func fmt(_ v: Double, _ places: Int = 0) -> String {
    guard v.isFinite else { return "-" }
    if places == 0 { return String(Int(v.rounded())) }
    return String(format: "%.\(places)f", v)
}
