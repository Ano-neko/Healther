import Foundation
import HealtherCore

// healther — terminal client for developing the agent on Linux/macOS with mock Apple Health data.
//
//   healther                       interactive chat
//   healther ask "text" [--photo path]...   one turn, then exit (scripting / tests)
//
// Config: DEEPSEEK_API_KEY from the environment or ~/.config/healther/env (KEY=VALUE lines).
//         HEALTHER_DATA_DIR (default ~/.local/share/healther) — personal data, never inside the repo.

enum ANSI {
    static let isTTY = isatty(1) == 1
    static func wrap(_ s: String, _ code: String) -> String { isTTY ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func magenta(_ s: String) -> String { wrap(s, "35") }
}

func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

func loadEnvFile() -> [String: String] {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/healther/env")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
    var env: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
        env[String(t[..<eq])] = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
    return env
}

func mimeType(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "png": return "image/png"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    default: return "image/jpeg"
    }
}

func renderMeal(_ meal: Meal, clock: DayClock) -> String {
    if meal.items.isEmpty { return ANSI.yellow("  ✕ 已删除 \(meal.type.displayName)") }
    let status = meal.status == .draft ? ANSI.yellow("草稿 #\(meal.shortID)") : ANSI.green("已记录 ✓")
    var lines = ["  ┌─ \(meal.type.displayName) \(clock.timeString(meal.eatenAt))  \(status)"]
    for i in meal.items {
        let conf = i.confidence == .low ? ANSI.yellow(" ?") : ""
        let name = i.name.padding(toLength: max(i.name.count, 10), withPad: "　", startingAt: 0)
        lines.append("  │ \(name) \(String(format: "%5.0f", i.grams))g  \(String(format: "%5.0f", i.nutrients.kcal)) kcal  \(ANSI.dim(i.source.displayName))\(conf)")
    }
    let t = meal.totals
    lines.append("  └─ 合计 \(ANSI.bold(String(format: "%.0f kcal", t.kcal)))  蛋白 \(String(format: "%.0f", t.protein))g · 脂肪 \(String(format: "%.0f", t.fat))g · 碳水 \(String(format: "%.0f", t.carbs))g")
    return lines.joined(separator: "\n")
}

struct CLI {
    let services: HealtherServices
    let agent: HealtherAgent
    var showThinking = false

    func turn(_ input: UserInput) async {
        let name = services.config.assistantName
        var printedName = false
        var inReasoning = false
        func header() {
            if inReasoning { out("\n"); inReasoning = false }
            if !printedName { out("\n" + ANSI.magenta(ANSI.bold(name)) + "  "); printedName = true }
        }
        do {
            for try await e in agent.send(input) {
                switch e {
                case .reasoning(let r):
                    if showThinking {
                        if !inReasoning { out(ANSI.dim("\n  💭 ")); inReasoning = true }
                        out(ANSI.dim(r.replacingOccurrences(of: "\n", with: "\n     ")))
                    }
                case .text(let t):
                    header()
                    out(t)
                case .toolStarted:
                    if inReasoning { out("\n"); inReasoning = false }
                case .toolFinished(let n, let summary, let isError):
                    out(isError ? ANSI.red("\n  ✗ \(n) · \(summary)") : ANSI.cyan("\n  ⚙︎ \(n) · \(summary)"))
                case .mealUpdated(let meal):
                    out("\n" + renderMeal(meal, clock: services.clock))
                case .memoryChanged:
                    break  // already shown by the tool's summary line
                case .assistantMessage(let m):
                    if !m.content.isEmpty { printedName = false; out("\n") }
                case .turnFinished(let u):
                    out(ANSI.dim("\n  [tokens: 输入 \(u.promptTokens)（缓存 \(u.cacheHitTokens)） 输出 \(u.completionTokens)]\n"))
                case .maintenance(let m):
                    out(ANSI.dim("  ⟳ \(m)\n"))
                }
            }
        } catch {
            out(ANSI.red("\n出错了：\(error)\n"))
        }
        out("\n")
    }

    func command(_ line: String) async -> Bool {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let clock = services.clock
        do {
            switch parts[0] {
            case "/quit", "/exit", "/q":
                return false
            case "/help":
                out("""
                /photo <路径> [说明]   发送照片（可多张：用 | 分隔路径）
                /today                 查看「此刻」状态块
                /context               打印完整上下文（调试）
                /profile               档案        /memories [关键词]   记忆
                /diary                 日记        /meals [YYYY-MM-DD]  饮食记录
                /foods                 个人食物库
                /compact               强制整理对话   /reflect [YYYY-MM-DD]  写日记
                /hello                 让伙伴主动打招呼
                /wake [HH:mm]          模拟起床后的问候（可指定“现在”）
                /plan [HH:mm]          写好今天剩下的主动消息   /deliver [HH:mm]  投递到点的消息
                /persona [文件.json]    查看 / 载入人设 {"identity","personality"}
                /export [路径]          导出核心记忆为 Markdown
                /think                 显示/隐藏思考过程
                /usage                 累计 token 用量
                /quit

                """)
            case "/photo":
                let segs = arg.split(separator: " ", maxSplits: 1).map(String.init)
                guard let pathList = segs.first else { out("用法：/photo <路径> [说明]\n"); return true }
                var images: [UserInput.Image] = []
                for p in pathList.split(separator: "|").map(String.init) {
                    let path = (p as NSString).expandingTildeInPath
                    guard let data = FileManager.default.contents(atPath: path) else { out(ANSI.red("读不到 \(path)\n")); return true }
                    images.append(.init(data: data, mimeType: mimeType(for: path)))
                }
                await turn(UserInput(text: segs.count > 1 ? segs[1] : "", images: images))
            case "/today":
                let ctx = try await agent.debugContext(userText: arg)
                out(ctx.first { $0.role == .system && $0.text.hasPrefix("## 此刻") }?.text ?? "")
                out("\n")
            case "/context":
                for m in try await agent.debugContext(userText: arg) {
                    out(ANSI.bold("\n━━ \(m.role.rawValue) ━━\n"))
                    out(m.text + "\n")
                    for c in m.toolCalls { out(ANSI.cyan("  → \(c.name) \(c.arguments)\n")) }
                }
            case "/profile":
                out(try services.profile.render() + "\n")
            case "/memories":
                if arg.isEmpty {
                    for m in try services.memories.active(limit: 100) {
                        out("#\(m.id) [\(m.kind.title)·\(m.importance)] \(m.content) \(ANSI.dim(clock.dayKey(m.createdAt)))\n")
                    }
                } else {
                    for h in try services.memories.recall(arg, limit: 10, touch: false) {
                        out("#\(h.memory.id) \(String(format: "%.2f", h.score)) \(h.memory.content)\n")
                    }
                }
            case "/diary":
                for e in try services.episodes.recent(14, before: "9999").reversed() {
                    out(ANSI.bold(e.day) + " " + (e.mood ?? "") + "\n" + e.summary + "\n\n")
                }
            case "/meals":
                let day = clock.parse(arg, relativeTo: Date()) ?? Date()
                let meals = try services.meals.meals(from: clock.startOfDay(day), to: clock.endOfDay(day), includeDrafts: true)
                if meals.isEmpty { out("（\(clock.dayKey(day)) 没有记录）\n") }
                for m in meals { out(renderMeal(m, clock: clock) + "\n") }
            case "/foods":
                for f in try services.personalFoods.all() {
                    out("\(f.id) \(f.name) \(String(format: "%.0f", f.per100g.kcal))kcal/100g 常吃 \(f.typicalGrams.map { String(format: "%.0f", $0) } ?? "-")g ×\(f.useCount ?? 0)\n")
                }
            case "/compact":
                out(try await agent.forceCompact() ? "已整理\n" : "没有可整理的内容\n")
            case "/reflect":
                let day = clock.parse(arg, relativeTo: Date()) ?? Date()
                out(try await agent.reflect(day: day) ? "已写 \(clock.dayKey(day)) 的日记\n" : "这天没有内容\n")
            case "/usage":
                let u = services.totalUsage
                out("累计：输入 \(u.promptTokens) tokens（缓存命中 \(u.cacheHitTokens)），输出 \(u.completionTokens)（含思考 \(u.reasoningTokens)）\n")
            case "/hello":
                if let m = try await agent.sayHello() { out(ANSI.bold("\(services.config.assistantName)：") + m.content + "\n") }
            case "/wake":
                let now = clock.parse(arg, relativeTo: Date()) ?? Date()
                if let m = try await agent.greetIfJustWokeUp(now: now) {
                    out(ANSI.bold("\(services.config.assistantName)：") + m.content + "\n")
                } else {
                    out("（没有触发：今天已问候过、没有刚结束的睡眠，或已关闭）\n")
                }
            case "/plan":
                let now = clock.parse(arg, relativeTo: Date()) ?? Date()
                let planned = try await agent.planDayIfNeeded(now: now)
                if planned.isEmpty { out("（今天已经写好了，或没有剩余时段）\n") }
                for m in services.proactive.queue {
                    out("\(clock.timeString(m.fireAt)) [\(m.kind.rawValue)] \(m.text)\n")
                }
            case "/deliver":
                let now = clock.parse(arg, relativeTo: Date()) ?? Date()
                for m in try await agent.deliverDue(now: now) { out(ANSI.bold("\(services.config.assistantName)（主动）：") + m.content + "\n") }
            case "/persona":
                if !arg.isEmpty {
                    let path = (arg as NSString).expandingTildeInPath
                    guard let data = FileManager.default.contents(atPath: path) else { out(ANSI.red("读不到 \(path)\n")); return true }
                    try services.persona.save(try JSONDecoder().decode(PersonaProfile.self, from: data))
                    out("已载入。重启 CLI 后生效。\n")
                }
                let p = services.persona.current
                out(ANSI.bold("身份核心\n") + p.identity + "\n\n" + ANSI.bold("性格\n") + p.personality + "\n")
            case "/export":
                let md = try MemoryExporter.markdown(services)
                let path = arg.isEmpty ? MemoryExporter.fileName(services) : (arg as NSString).expandingTildeInPath
                try md.write(toFile: path, atomically: true, encoding: .utf8)
                out("已导出到 \(path)（\(md.count) 字）\n")
            default:
                out("未知命令，/help 查看帮助\n")
            }
        } catch {
            out(ANSI.red("出错了：\(error)\n"))
        }
        return true
    }
}

// MARK: - Entry

let env = loadEnvFile().merging(ProcessInfo.processInfo.environment) { _, process in process }
guard let apiKey = env["DEEPSEEK_API_KEY"], !apiKey.isEmpty else {
    out("需要 DEEPSEEK_API_KEY（环境变量或 ~/.config/healther/env）\n")
    exit(1)
}
let dataDir = URL(fileURLWithPath: (env["HEALTHER_DATA_DIR"] ?? "~/.local/share/healther" as String).replacingOccurrences(
    of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path))

var models = ModelConfig.deepSeekDefault
if let m = env["HEALTHER_CHAT_MODEL"] { models.chatModel = m }
if let e = env["HEALTHER_EFFORT"].flatMap(ReasoningEffort.init(rawValue:)) { models.chatEffort = e }
let config = HealtherConfig(assistantName: env["HEALTHER_NAME"] ?? "大肥鱼", models: models, dataDirectory: dataDir)
let llm = OpenAICompatibleClient(baseURL: URL(string: env["HEALTHER_BASE_URL"] ?? "https://api.deepseek.com")!, apiKey: apiKey)

let services: HealtherServices
do {
    services = try HealtherServices.make(config: config, llm: llm)
} catch {
    out("初始化失败：\(error)\n")
    exit(1)
}
var cli = CLI(services: services, agent: HealtherAgent(services: services))

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "ask" {
    var text: [String] = []
    var images: [UserInput.Image] = []
    var i = 1
    while i < args.count {
        if args[i] == "--photo", i + 1 < args.count {
            let path = args[i + 1]
            guard let data = FileManager.default.contents(atPath: path) else { out("读不到 \(path)\n"); exit(1) }
            images.append(.init(data: data, mimeType: mimeType(for: path)))
            i += 2
        } else if args[i] == "--think" {
            cli.showThinking = true
            i += 1
        } else {
            text.append(args[i])
            i += 1
        }
    }
    await cli.turn(UserInput(text: text.joined(separator: " "), images: images))
    exit(0)
} else if args.first == "cmd", args.count > 1 {
    _ = await cli.command(args.dropFirst().joined(separator: " "))
    exit(0)
}

out(ANSI.bold("Healther") + ANSI.dim("  数据目录 \(dataDir.path)  ·  \(services.health.isMock ? "模拟健康数据" : "Apple 健康")  ·  /help\n"))
while true {
    out(ANSI.green("\n你 › "))
    guard let line = readLine(strippingNewline: true) else { break }
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { continue }
    if t.hasPrefix("/") {
        if t == "/think" {
            cli.showThinking.toggle()
            out("思考过程：\(cli.showThinking ? "显示" : "隐藏")\n")
            continue
        }
        if !(await cli.command(t)) { break }
    } else {
        await cli.turn(UserInput(text: t))
    }
}
