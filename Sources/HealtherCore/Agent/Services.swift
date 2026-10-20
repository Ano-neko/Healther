import Foundation

public struct HealtherConfig: Sendable {
    public var assistantName: String
    public var models: ModelConfig
    public var dataDirectory: URL
    /// Uncompacted history above this (estimated tokens) triggers compaction.
    public var compactThresholdTokens: Int
    /// How much recent history survives a compaction verbatim.
    public var keepRecentTokens: Int
    public var autoRecallLimit: Int
    public var maxToolSteps: Int

    public init(assistantName: String = "小禾", models: ModelConfig = .deepSeekDefault, dataDirectory: URL,
                compactThresholdTokens: Int = 24_000, keepRecentTokens: Int = 10_000, autoRecallLimit: Int = 6, maxToolSteps: Int = 10) {
        self.assistantName = assistantName
        self.models = models
        self.dataDirectory = dataDirectory
        self.compactThresholdTokens = compactThresholdTokens
        self.keepRecentTokens = keepRecentTokens
        self.autoRecallLimit = autoRecallLimit
        self.maxToolSteps = maxToolSteps
    }
}

/// Everything the agent and tools need, wired once at startup.
public final class HealtherServices: Sendable {
    public let config: HealtherConfig
    public let clock: DayClock
    public let db: SQLiteDatabase
    public let llm: any LLMClient
    public let health: any HealthDataSource
    public let profile: ProfileStore
    public let memories: MemoryStore
    public let episodes: EpisodeStore
    public let conversation: ConversationStore
    public let meals: MealStore
    public let wellbeing: WellbeingStore
    public let personalFoods: PersonalFoodLibrary
    public let foodSearch: FoodSearchService
    public let barcode: OpenFoodFactsSource
    public let kv: KeyValueStore

    public var dayNotes: DayNoteStore { DayNoteStore(kv: kv) }

    public var attachmentsDirectory: URL { config.dataDirectory.appendingPathComponent("attachments", isDirectory: true) }

    public init(config: HealtherConfig, db: SQLiteDatabase, llm: any LLMClient, health: any HealthDataSource,
                foodTables: [any FoodDataSource], clock: DayClock = DayClock(), enableOnlineFood: Bool = true) {
        self.config = config
        self.clock = clock
        self.db = db
        self.llm = llm
        self.health = health
        profile = ProfileStore(db: db)
        memories = MemoryStore(db: db)
        episodes = EpisodeStore(db: db)
        conversation = ConversationStore(db: db)
        meals = MealStore(db: db)
        wellbeing = WellbeingStore(db: db)
        personalFoods = PersonalFoodLibrary(db: db)
        barcode = OpenFoodFactsSource()
        foodSearch = FoodSearchService(personal: personalFoods, offline: foodTables, online: enableOnlineFood ? [barcode] : [])
        kv = KeyValueStore(db: db)
    }

    /// Standard on-disk setup: `<dataDirectory>/healther.sqlite` plus the bundled food table.
    public static func make(config: HealtherConfig, llm: any LLMClient, health: ((SQLiteDatabase) -> any HealthDataSource)? = nil,
                            clock: DayClock = DayClock()) throws -> HealtherServices {
        let db = try UserDatabase.open(at: config.dataDirectory.appendingPathComponent("healther.sqlite"))
        let healthSource = health?(db) ?? MockHealthDataSource(db: db, clock: clock)
        let tables: [any FoodDataSource] = [try BundledFoodDatabase.bundled()]
        return HealtherServices(config: config, db: db, llm: llm, health: healthSource, foodTables: tables, clock: clock)
    }

    // MARK: Usage accounting (so a ¥10 balance doesn't surprise anyone)

    public var totalUsage: ChatUsage {
        kv.get("usage.total").flatMap { try? JSONDecoder().decode(ChatUsage.self, from: Data($0.utf8)) } ?? ChatUsage()
    }

    public func addUsage(_ u: ChatUsage) {
        let total = totalUsage + u
        if let data = try? JSONEncoder().encode(total) { try? kv.set("usage.total", String(decoding: data, as: UTF8.self)) }
    }
}
