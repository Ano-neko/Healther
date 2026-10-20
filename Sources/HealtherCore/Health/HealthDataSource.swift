import Foundation

/// Abstraction over Apple Health. `HealthKitDataSource` on device, `MockHealthDataSource` on Linux/tests.
public protocol HealthDataSource: Sendable {
    var isMock: Bool { get }
    func requestAuthorization() async throws
    func dailySummary(for day: Date) async throws -> DailyHealthSummary
    /// One value per local day, oldest first, ending with the day containing `end`.
    func dailyValues(_ metric: HealthMetric, days: Int, endingAt end: Date) async throws -> [DailyValue]

    func save(_ measurement: BodyMeasurement, at date: Date) async throws
    func save(meal: Meal) async throws
    func deleteMeal(id: UUID) async throws
    func saveWater(ml: Double, at date: Date) async throws
    func save(mood: MoodEntry) async throws
    /// What Apple Health knows about the body itself (birth date, sex, latest height).
    func characteristics() async -> HealthCharacteristics
}

public struct HealthCharacteristics: Codable, Sendable, Equatable {
    public var birthYear: Int?
    /// "female" / "male" (BodyProfile.Sex raw values); nil when unknown.
    public var sex: String?
    public var heightCm: Double?

    public init(birthYear: Int? = nil, sex: String? = nil, heightCm: Double? = nil) {
        self.birthYear = birthYear
        self.sex = sex
        self.heightCm = heightCm
    }
}

public enum HealthDataError: Error, CustomStringConvertible {
    case unavailable
    case notAuthorized(String)

    public var description: String {
        switch self {
        case .unavailable: return "此设备不支持健康数据"
        case .notAuthorized(let what): return "没有\(what)的健康数据权限"
        }
    }
}
