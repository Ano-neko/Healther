import Foundation
import HealtherCore

/// User-facing settings. Everything except the API key is in UserDefaults.
struct AppSettings: Equatable {
    var assistantName: String
    var baseURL: String
    var chatModel: String
    var effort: ReasoningEffort
    var useMockHealth: Bool

    static let defaults = UserDefaults.standard

    static func load() -> AppSettings {
        AppSettings(
            assistantName: defaults.string(forKey: "assistantName") ?? "小禾",
            baseURL: defaults.string(forKey: "baseURL") ?? "https://api.deepseek.com",
            chatModel: defaults.string(forKey: "chatModel") ?? "deepseek-flash",
            effort: ReasoningEffort(rawValue: defaults.string(forKey: "effort") ?? "") ?? .low,
            useMockHealth: defaults.bool(forKey: "useMockHealth")
        )
    }

    func save() {
        let d = Self.defaults
        d.set(assistantName, forKey: "assistantName")
        d.set(baseURL, forKey: "baseURL")
        d.set(chatModel, forKey: "chatModel")
        d.set(effort.rawValue, forKey: "effort")
        d.set(useMockHealth, forKey: "useMockHealth")
    }

    static var apiKey: String? {
        get { Keychain.get("api-key") }
        set { Keychain.set(newValue, for: "api-key") }
    }
}
