import Foundation

/// Background memory maintenance, run between turns:
/// - **Compaction**: when uncompacted history grows past a budget, fold the oldest part into the
///   rolling summary and extract durable memories / profile updates from it.
/// - **Reflection**: once a day has passed, write a diary entry (episode) for it.
struct MemoryCurator {
    let s: HealtherServices

    var clock: DayClock { s.clock }

    // MARK: Transcript

    func transcript(_ msgs: [ConversationStore.Message], maxTokens: Int = 14_000) -> String {
        var lines: [String] = []
        for m in msgs {
            let t = "[\(clock.stamp(m.createdAt).dropFirst(5))]"
            switch m.role {
            case .user:
                let photos = (m.payload.attachments?.isEmpty ?? true) ? "" : "（附照片）"
                lines.append("\(t) 用户：\(m.content)\(photos)")
            case .assistant:
                if !m.content.isEmpty { lines.append("\(t) \(s.config.assistantName)：\(m.content)") }
                for c in m.payload.toolCalls ?? [] { lines.append("    （调用 \(c.name) \(c.arguments.prefix(160))）") }
            case .tool:
                lines.append("    （结果 \(m.payload.toolName ?? ""): \(m.content.prefix(160))）")
            case .system:
                continue
            }
        }
        // Keep the most recent part if too long.
        var total = 0
        var kept: [String] = []
        for line in lines.reversed() {
            total += TokenEstimator.estimate(line)
            if total > maxTokens { kept.append("（更早的内容已省略）"); break }
            kept.append(line)
        }
        return kept.reversed().joined(separator: "\n")
    }

    // MARK: Compaction

    @discardableResult
    func compactIfNeeded(force: Bool = false) async throws -> Bool {
        let msgs = try s.conversation.uncompacted()
        let total = msgs.reduce(0) { $0 + TokenEstimator.estimate($1) }
        guard force || total > s.config.compactThresholdTokens else { return false }

        // Keep roughly `keepRecentTokens` of the newest messages, starting at a user message.
        var kept = 0
        var cut = msgs.count
        for i in stride(from: msgs.count - 1, through: 0, by: -1) {
            kept += TokenEstimator.estimate(msgs[i])
            if kept > s.config.keepRecentTokens { break }
            cut = i
        }
        if force { cut = max(0, msgs.count - 2) }
        while cut < msgs.count, msgs[cut].role != .user { cut += 1 }
        guard cut > 0 else { return false }
        let chunk = Array(msgs[..<cut])

        let chunkText = transcript(chunk, maxTokens: 30_000)
        let related = (try? s.memories.recall(chunk.filter { $0.role == .user }.map(\.content).joined(separator: " "), limit: 15, touch: false)) ?? []
        let prompt = """
        你在帮健康陪伴助手「\(s.config.assistantName)」整理记忆。下面是一段较早的对话，它即将从上下文中移除。请输出 JSON：

        {
          "summary": "更新后的前情提要",
          "memories": [{"content": "...", "kind": "fact|preference|health|event|emotion|insight|commitment", "importance": 1-5, "tags": ["..."], "replaces": 旧记忆id或null}],
          "profile": [{"section": "basics|health|goals|diet|routine|personality|relationship", "key": "...", "value": "...或null表示删除"}]
        }

        要求：
        - summary：把「已有前情提要」和这段对话合并改写成一段连贯摘要（不超过 600 字）。保留仍然重要的上下文：正在聊的话题、TA 的近况和情绪、未完成的事、你答应过的事。删掉已经过时或无关紧要的细节。\(pronounRule)
        - memories：只提取长期有价值、且「已有记忆」里没有的信息；与已有记忆矛盾或更新时，填 replaces。没有就给空数组。不要记录饮食明细和健康数据数字（它们另有存储）。
        - profile：只在档案信息需要新增或修改时输出。
        - 只输出 JSON。

        ## 当前档案
        \(try s.profile.render())

        ## 已有记忆（可能相关）
        \(related.isEmpty ? "（无）" : related.map { "- #\($0.memory.id) [\($0.memory.kind.rawValue)] \($0.memory.content)" }.joined(separator: "\n"))

        ## 已有前情提要
        \(s.conversation.rollingSummary ?? "（无）")

        ## 要整理的对话
        \(chunkText)
        """
        let result = try await utilityJSON(prompt)
        guard let summary = result["summary"]?.stringValue, !summary.isEmpty else {
            throw LLMError.invalidResponse("compaction returned no summary")
        }
        try s.db.transaction {
            try s.conversation.setRollingSummary(summary)
            try s.conversation.markCompacted(throughID: chunk.last!.id)
        }
        applyMemoryOps(result, source: "compaction")
        return true
    }

    // MARK: Reflection

    /// Writes diary entries for finished days that don't have one yet (at most `maxDays` back).
    func reflectPendingDays(now: Date, maxDays: Int = 7) async throws -> [String] {
        let yesterday = clock.addDays(-1, to: clock.startOfDay(now))
        let cursorKey = "reflection.last_day"
        var start: Date
        if let last = s.kv.get(cursorKey).flatMap(clock.date(fromDayKey:)) {
            start = clock.addDays(1, to: last)
        } else if let first = try s.conversation.firstMessageDate() {
            start = clock.startOfDay(first)
        } else {
            return []
        }
        start = max(start, clock.addDays(-(maxDays - 1), to: yesterday))
        var done: [String] = []
        var day = start
        while day <= yesterday {
            if try await reflect(day: day) { done.append(clock.dayKey(day)) }
            try s.kv.set(cursorKey, clock.dayKey(day))
            day = clock.addDays(1, to: day)
        }
        return done
    }

    /// Returns false if there was nothing to reflect on.
    @discardableResult
    func reflect(day: Date) async throws -> Bool {
        let start = clock.startOfDay(day), end = clock.endOfDay(day)
        let msgs = try s.conversation.messages(from: start, to: end)
        let meals = try s.meals.meals(from: start, to: end)
        let moods = try s.wellbeing.moods(from: start, to: end)
        guard !msgs.isEmpty || !meals.isEmpty || !moods.isEmpty else { return false }
        let health = try? await s.healthSummary(for: day)
        let nutrition = try s.meals.totals(from: start, to: end)

        let prompt = """
        你是健康陪伴助手「\(s.config.assistantName)」。现在给 \(clock.dayKey(day))（\(clock.weekdayName(day))）写一篇简短的日记，记录你和 TA 的这一天。输出 JSON：

        {
          "summary": "120–250 字。这一天 TA 过得怎么样：发生了什么、聊了什么、身体和饮食的要点、情绪状态。\(pronounRule)语气温暖自然，像你自己的日记。",
          "mood": "一个短语概括 TA 当天状态，如“疲惫但充实”",
          "highlights": ["值得以后提起的 1–3 个点"],
          "memories": [{"content": "...", "kind": "fact|preference|health|event|emotion|insight|commitment", "importance": 1-5, "tags": [], "replaces": null}]
        }

        memories 只放长期有价值、且不在档案里的新信息（比如一个规律：“周末晚睡后周一 HRV 偏低”）。没有就给空数组。只输出 JSON。

        ## 档案
        \(try s.profile.render())

        ## 当天数据
        - 健康：\(health.map { $0.json(clock: clock).jsonString() } ?? "无")
        - 饮食合计：\(nutrition.json.jsonString())；共 \(meals.count) 餐：\(meals.map { "\($0.type.displayName) \($0.items.map(\.name).joined(separator: "、"))" }.joined(separator: "；"))
        - 情绪记录：\(moods.isEmpty ? "无" : moods.map { "\(clock.timeString($0.at)) \($0.valence) \($0.labels.joined(separator: "/")) \($0.note ?? "")" }.joined(separator: "；"))

        ## 当天对话
        \(msgs.isEmpty ? "（这天没有聊天）" : transcript(msgs))
        """
        let result = try await utilityJSON(prompt)
        guard let summary = result["summary"]?.stringValue, !summary.isEmpty else { return false }
        try s.episodes.save(day: clock.dayKey(day), summary: summary, mood: result["mood"]?.stringValue,
                            highlights: result["highlights"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        applyMemoryOps(result, source: "reflection", at: end.addingTimeInterval(-60))
        return true
    }

    // MARK: Helpers

    /// Don't infer gender from a name: only use 他/她 if the profile states it.
    var pronounRule: String {
        let gender = s.profile.value(.basics, "性别")
        if let gender { return "用户性别：\(gender)。指代用户时用称呼或相应代词。" }
        return "档案里没有记录性别：指代用户时只用称呼或“TA”，绝对不要用“他”或“她”。"
    }

    func utilityJSON(_ prompt: String) async throws -> JSONValue {
        let req = ChatRequest(model: s.config.models.utilityModel, messages: [.user(prompt)],
                              effort: s.config.models.reflectionEffort, temperature: 0.3, jsonOutput: true)
        let r = try await s.llm.complete(req)
        s.addUsage(r.usage)
        return try Self.parseJSON(r.message.text)
    }

    static func parseJSON(_ text: String) throws -> JSONValue {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let r = t.range(of: "```", options: .backwards) { t = String(t[..<r.lowerBound]) }
        }
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}") { t = String(t[a...b]) }
        return try JSONValue.parse(t)
    }

    @discardableResult
    func applyMemoryOps(_ v: JSONValue, source: String, at: Date = Date()) -> [String] {
        var log: [String] = []
        for m in v["memories"]?.arrayValue ?? [] {
            guard let content = m["content"]?.stringValue, !content.isEmpty else { continue }
            let kind = MemoryStore.Kind(rawValue: m["kind"]?.stringValue ?? "") ?? .fact
            if let mem = try? s.memories.remember(content, kind: kind, importance: m["importance"]?.intValue ?? 3,
                                                  tags: m["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                                  replaces: m["replaces"]?.intValue, source: source, now: at) {
                log.append("记忆 #\(mem.id)：\(mem.content)")
            }
        }
        for p in v["profile"]?.arrayValue ?? [] {
            guard let sec = ProfileStore.Section(rawValue: p["section"]?.stringValue ?? ""), let key = p["key"]?.stringValue else { continue }
            let value = p["value"]?.stringValue
            if (try? s.profile.set(sec, key, value)) != nil { log.append("档案 \(sec.title)/\(key)：\(value ?? "（删除）")") }
        }
        return log
    }
}
