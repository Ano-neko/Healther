import Foundation

enum MemoryTools {
    static let all: [any AgentTool] = [RememberTool(), RecallTool(), ForgetTool(), UpdateProfileTool(), DiaryTool()]
}

struct RememberTool: AgentTool {
    let name = "remember"
    let description = "存一条长期记忆（具体的事、情绪变化、规律、约定、偏好细节）。一条只记一件事，写成以后能看懂的完整句子。信息更新时用 replaces 覆盖旧记忆。"
    let parameters = Schema.object([
        "content": Schema.string("如“10 月开始准备 CPA 考试，晚上常学习到 1 点”"),
        "kind": Schema.string("类型", enum: MemoryStore.Kind.allCases.map(\.rawValue)),
        "importance": Schema.integer("1 琐碎 … 5 非常重要（健康风险、核心目标）", minimum: 1, maximum: 5),
        "tags": Schema.array(Schema.string("标签"), "便于检索的关键词"),
        "replaces": Schema.integer("被这条取代的旧记忆 id"),
    ], required: ["content", "kind"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let content = args["content"]?.stringValue, !content.isEmpty else { return .error("content 为空") }
        let kind = MemoryStore.Kind(rawValue: args["kind"]?.stringValue ?? "") ?? .fact
        let m = try ctx.services.memories.remember(
            content, kind: kind, importance: args["importance"]?.intValue ?? 3,
            tags: args["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [], replaces: args["replaces"]?.intValue, now: ctx.now)
        return ToolResult(["ok": true, "memory_id": .number(Double(m.id))], summary: "记住了：\(m.content)",
                          events: [.memoryChanged("记忆 #\(m.id)：\(m.content)")])
    }
}

struct RecallTool: AgentTool {
    let name = "recall"
    let description = "检索长期记忆（关键词匹配，按相关度、重要性、时间排序）。回答涉及过去的事之前、或要更新旧记忆前使用。"
    let parameters = Schema.object([
        "query": Schema.string("关键词，可以多个，如“咖啡 睡眠”"),
        "limit": Schema.integer("默认 8", minimum: 1, maximum: 20),
    ], required: ["query"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let q = args["query"]?.stringValue ?? ""
        let hits = try ctx.services.memories.recall(q, limit: args["limit"]?.intValue ?? 8, now: ctx.now)
        let o: JSONValue = ["memories": .array(hits.map { $0.memory.json(clock: ctx.clock) })]
        return ToolResult(o, summary: "回忆「\(q)」：\(hits.count) 条")
    }
}

struct ForgetTool: AgentTool {
    let name = "forget"
    let description = "删除一条记忆（用户要求忘掉，或记错了）。"
    let parameters = Schema.object(["memory_id": Schema.integer("记忆 id")], required: ["memory_id"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let id = args["memory_id"]?.intValue, let m = try ctx.services.memories.get(id) else { return .error("没有这条记忆") }
        try ctx.services.memories.forget(id)
        return ToolResult(["ok": true], summary: "忘掉了 #\(id)", events: [.memoryChanged("删除记忆：\(m.content)")])
    }
}

struct UpdateProfileTool: AgentTool {
    let name = "update_profile"
    let description = "更新用户档案（每次对话都会带上的核心信息）。只放稳定、重要、简短的信息。value 为 null 表示删除该项。"
    let parameters = Schema.object([
        "section": Schema.string(ProfileStore.Section.allCases.map { "\($0.rawValue)=\($0.title)（\($0.hint)）" }.joined(separator: "；"),
                                 enum: ProfileStore.Section.allCases.map(\.rawValue)),
        "key": Schema.string("条目名，如“称呼”“过敏”“减脂目标”"),
        "value": Schema.nullable(Schema.string("简短的值，如“小林”“对花生过敏”")),
    ], required: ["section", "key", "value"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        guard let section = ProfileStore.Section(rawValue: args["section"]?.stringValue ?? ""),
              let key = args["key"]?.stringValue, !key.isEmpty else { return .error("section/key 无效") }
        let value = args["value"]?.stringValue
        try ctx.services.profile.set(section, key, value, now: ctx.now)
        let label = "\(section.title)/\(key)：\(value ?? "（删除）")"
        return ToolResult(["ok": true], summary: "档案 \(label)", events: [.memoryChanged("档案 \(label)")])
    }
}

struct DiaryTool: AgentTool {
    let name = "read_diary"
    let description = "读你写的日记（每天一篇，总结那天 TA 的状态和你们聊的事）。用于回顾某段时间。"
    let parameters = Schema.object([
        "from": Schema.string("开始日期 YYYY-MM-DD"),
        "to": Schema.string("结束日期 YYYY-MM-DD（含），默认今天"),
    ], required: ["from"])

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> ToolResult {
        let from = args["from"]?.stringValue ?? ctx.clock.dayKey(ctx.now)
        let to = args["to"]?.stringValue ?? ctx.clock.dayKey(ctx.now)
        let eps = try ctx.services.episodes.range(from: from, to: to).suffix(31)
        let o: JSONValue = ["entries": .array(eps.map {
            ["day": .string($0.day), "summary": .string($0.summary), "mood": JSONValue($0.mood), "highlights": .array($0.highlights.map(JSONValue.string))]
        })]
        return ToolResult(o, summary: "翻了 \(eps.count) 篇日记")
    }
}
