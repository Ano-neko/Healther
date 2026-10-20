import Foundation
import HealtherCore
import Observation
import UIKit

/// One row in the chat transcript.
enum ChatItem: Identifiable, Equatable {
    case user(id: String, text: String, photos: [String], date: Date)
    case assistant(id: String, text: String, date: Date)
    case meal(id: String, mealID: UUID)
    case activity(id: String, steps: [ToolStep])

    var id: String {
        switch self {
        case .user(let id, _, _, _), .assistant(let id, _, _), .meal(let id, _), .activity(let id, _): return id
        }
    }
}

struct ToolStep: Identifiable, Equatable {
    let id = UUID()
    var tool: String
    var summary: String?
    var isError = false
    var done: Bool { summary != nil }

    var title: String {
        switch tool {
        case "search_food": return "查营养库"
        case "lookup_barcode": return "查条码"
        case "draft_meal": return "整理这一餐"
        case "confirm_meal": return "记入饮食"
        case "delete_meal": return "删除记录"
        case "get_meals": return "翻看饮食记录"
        case "save_personal_food": return "存进我的食物库"
        case "get_health_overview": return "看今天的数据"
        case "query_health_trend": return "看趋势"
        case "log_body_measurement": return "记录身体数据"
        case "log_water": return "记录饮水"
        case "log_mood": return "记下心情"
        case "set_goal": return "设置目标"
        case "remember": return "记在心里"
        case "recall": return "回想"
        case "forget": return "忘掉"
        case "update_profile": return "更新档案"
        case "read_diary": return "翻日记"
        default: return tool
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var settings = AppSettings.load()
    var hasAPIKey = AppSettings.apiKey?.isEmpty == false
    private(set) var services: HealtherServices?
    private var agent: HealtherAgent?
    var setupError: String?

    // Chat
    var items: [ChatItem] = []
    var meals: [UUID: Meal] = [:]
    var streamingText = ""
    var isResponding = false
    var orb: OrbState = .idle
    var status = ""
    var lastError: String?
    /// Composer contents; lives here so a failed send can hand the text and photos back.
    var draft = ""
    var draftPhotos: [UIImage] = []
    private var turnTask: Task<Void, Never>?

    // Today
    var today = TodaySnapshot()

    var assistantName: String { settings.assistantName }

    // MARK: Lifecycle

    func bootstrap() {
        #if DEBUG
        importDevKeyIfPresent()
        #endif
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = support.appendingPathComponent("Healther", isDirectory: true)
            var models = ModelConfig.deepSeekDefault
            models.chatModel = settings.chatModel
            models.chatEffort = settings.effort
            let config = HealtherConfig(assistantName: settings.assistantName, models: models, dataDirectory: dir)
            let llm = OpenAICompatibleClient(baseURL: URL(string: settings.baseURL) ?? URL(string: "https://api.deepseek.com")!,
                                             apiKey: AppSettings.apiKey ?? "")
            let useMock = settings.useMockHealth || !HealthKitDataSource.isAvailable
            let s = try HealtherServices.make(config: config, llm: llm, health: { db in
                useMock ? MockHealthDataSource(db: db) as any HealthDataSource : HealthKitDataSource()
            })
            services = s
            agent = HealtherAgent(services: s)
            setupError = nil
            orb = hasAPIKey ? .idle : .offline
            reloadHistory()
            Task { await refreshToday() }
        } catch {
            setupError = "初始化失败：\(error)"
            orb = .offline
        }
    }

    #if DEBUG
    /// Development only: a key dropped into Documents/dev-api-key (e.g. with
    /// `devicectl device copy to --domain-type appDataContainer`) is moved into the keychain.
    private func importDevKeyIfPresent() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = docs.appendingPathComponent("dev-api-key")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let key = AppSettings.sanitizeKey(raw)
        guard !key.isEmpty else { return }
        AppSettings.apiKey = key
        hasAPIKey = true
    }
    #endif

    func applySettings(_ new: AppSettings, apiKey: String?) {
        settings = new
        settings.save()
        if let apiKey {
            AppSettings.apiKey = AppSettings.sanitizeKey(apiKey)
            hasAPIKey = AppSettings.apiKey?.isEmpty == false
        }
        bootstrap()
    }

    func requestHealthAccess() async {
        try? await services?.health.requestAuthorization()
        await refreshToday()
    }

    // MARK: Chat

    func reloadHistory() {
        guard let s = services else { return }
        let history = (try? s.conversation.history(limit: 300)) ?? []
        var out: [ChatItem] = []
        var mealPositions: [UUID: Int] = [:]
        for m in history {
            switch m.role {
            case .user:
                out.append(.user(id: "m\(m.id)", text: m.content, photos: m.payload.attachments?.map(\.file) ?? [], date: m.createdAt))
            case .assistant where !m.content.isEmpty:
                out.append(.assistant(id: "m\(m.id)", text: m.content, date: m.createdAt))
            case .tool where ["draft_meal", "confirm_meal"].contains(m.payload.toolName ?? ""):
                guard let ref = (try? JSONValue.parse(m.content))?["meal_id"]?.stringValue
                        ?? (try? JSONValue.parse(m.content))?["meal"]?["meal_id"]?.stringValue,
                      let meal = try? s.meals.find(ref) else { continue }
                meals[meal.id] = meal
                // Show each meal once, at its latest position.
                if let old = mealPositions[meal.id] { out[old] = .activity(id: "gone\(old)", steps: []) }
                mealPositions[meal.id] = out.count
                out.append(.meal(id: "meal\(m.id)", mealID: meal.id))
            default:
                continue
            }
        }
        items = out.filter { if case .activity(_, let steps) = $0 { return !steps.isEmpty } else { return true } }
    }

    func send(text: String, images: [UIImage] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agent, !isResponding, !(trimmed.isEmpty && images.isEmpty) else { return }
        guard hasAPIKey else {
            lastError = "先在设置里填好 API Key"
            return
        }
        let payloads = images.compactMap { ImageTools.prepareForUpload($0) }.map { UserInput.Image(data: $0, mimeType: "image/jpeg") }
        let pendingID = "pending-\(UUID().uuidString)"
        items.append(.user(id: pendingID, text: trimmed, photos: [], date: Date()))
        pendingPhotos[pendingID] = images
        isResponding = true
        streamingText = ""
        lastError = nil
        orb = .thinking
        status = "在想…"

        turnTask = Task {
            var activityID: String?
            do {
                for try await event in agent.send(UserInput(text: trimmed, images: payloads)) {
                    handle(event, activityID: &activityID)
                }
            } catch let e as TurnNotSent {
                lastError = Self.describe(e.underlying) + "\n消息已放回输入框，改好后再发一次。"
                if draft.isEmpty { draft = trimmed }
                if draftPhotos.isEmpty { draftPhotos = images }
            } catch {
                lastError = Self.describe(error)
            }
            flushStreaming()
            isResponding = false
            orb = .idle
            status = ""
            pendingPhotos.removeAll()
            reloadHistory()
            await refreshToday()
        }
    }

    /// Turns transport and API failures into something a person can act on.
    static func describe(_ error: Error) -> String {
        if let e = error as? LLMError {
            switch e {
            case .http(401, _), .http(403, _):
                return "模型服务拒绝了这个 API Key（\(e.statusCode ?? 0)）。去「设置」里重新粘贴一下 Key。"
            case .http(402, _):
                return "模型账户余额不足（402），充值后再聊。"
            case .http(429, _):
                return "请求太频繁了（429），稍等一会儿再试。"
            case .http(let s, _) where s >= 500:
                return "模型服务暂时出了问题（\(s)），过一会儿再试。"
            case .missingAPIKey:
                return "先在「设置」里填好 API Key。"
            case .cancelled:
                return "已停止。"
            default:
                return e.description
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "连不上网络。检查一下网络，或「设置 → Healther → 无线数据」是否允许。"
            case .timedOut:
                return "模型响应超时了，再发一次试试。"
            default:
                return "网络出错：\(u.localizedDescription)"
            }
        }
        if error is CancellationError { return "已停止。" }
        return "\(error)"
    }

    /// Photos picked for a message that is still in flight (before history reload gives us files).
    var pendingPhotos: [String: [UIImage]] = [:]

    func cancel() {
        turnTask?.cancel()
    }

    private func handle(_ event: AgentEvent, activityID: inout String?) {
        switch event {
        case .reasoning:
            orb = .thinking
            status = "在想…"
        case .text(let t):
            orb = .speaking
            status = "正在回复"
            streamingText += t
        case .toolStarted(let name):
            flushStreaming()
            orb = .working
            let step = ToolStep(tool: name)
            status = step.title + "…"
            if let id = activityID, let i = items.firstIndex(where: { $0.id == id }), case .activity(_, var steps) = items[i] {
                steps.append(step)
                items[i] = .activity(id: id, steps: steps)
            } else {
                let id = "act-\(UUID().uuidString)"
                activityID = id
                items.append(.activity(id: id, steps: [step]))
            }
        case .toolFinished(let name, let summary, let isError):
            if let id = activityID, let i = items.firstIndex(where: { $0.id == id }), case .activity(_, var steps) = items[i],
               let j = steps.firstIndex(where: { $0.tool == name && !$0.done }) {
                steps[j].summary = summary
                steps[j].isError = isError
                items[i] = .activity(id: id, steps: steps)
            }
        case .mealUpdated(let meal):
            meals[meal.id] = meal
            if !items.contains(where: { if case .meal(_, let id) = $0 { return id == meal.id } else { return false } }) {
                items.append(.meal(id: "live-\(meal.id)", mealID: meal.id))
            }
            activityID = nil
        case .assistantMessage:
            flushStreaming()
            activityID = nil
        case .memoryChanged, .maintenance:
            break
        case .turnFinished:
            status = ""
        }
    }

    private func flushStreaming() {
        let t = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { items.append(.assistant(id: "live-\(UUID().uuidString)", text: t, date: Date())) }
        streamingText = ""
    }

    func photoURL(_ file: String) -> URL? {
        services?.attachmentsDirectory.appendingPathComponent(file)
    }

    // MARK: Meal actions (direct, no model round-trip)

    func confirmMealFromCard(_ meal: Meal) {
        send(text: "确认，记吧")
    }

    // MARK: Today

    /// The day shown on the Today tab (start of day). Defaults to today.
    var todayDay = Calendar.current.startOfDay(for: Date())
    /// True while the user is looking at the current day, so it rolls over at midnight.
    private var followsToday = true

    func refreshToday() async {
        guard let s = services else { return }
        if followsToday { todayDay = Calendar.current.startOfDay(for: Date()) }
        let day = todayDay
        let snap = await TodaySnapshot.load(from: s, day: day)
        if day == todayDay { today = snap }
    }

    func showDay(_ day: Date) {
        let start = Calendar.current.startOfDay(for: min(day, Date()))
        guard start != todayDay else { return }
        todayDay = start
        followsToday = Calendar.current.isDateInToday(start)
        Task { await refreshToday() }
    }

    // MARK: Data management

    func clearConversation() {
        try? services?.conversation.clearAll()
        items = []
    }

    func deleteAllData() {
        guard let s = services else { return }
        let dir = s.config.dataDirectory
        services = nil
        agent = nil
        try? FileManager.default.removeItem(at: dir)
        items = []
        meals = [:]
        bootstrap()
    }
}
