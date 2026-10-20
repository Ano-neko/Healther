import Foundation
import HealtherCore

/// User-facing settings. Everything except the API key is in UserDefaults.
struct AppSettings: Equatable {
    var assistantName: String
    var baseURL: String
    var chatModel: String
    var effort: ReasoningEffort
    var useMockHealth: Bool

    static var defaults: UserDefaults { .standard }

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

    /// Cleans a pasted key: drops whitespace and invisible characters, and pulls out
    /// the `sk-…` token if it was pasted together with other text.
    static func sanitizeKey(_ raw: String) -> String {
        let visible = String(raw.unicodeScalars.filter { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }.map(Character.init))
        if let r = visible.range(of: #"sk-[A-Za-z0-9_\-]{16,}"#, options: .regularExpression) {
            return String(visible[r])
        }
        return visible
    }

    static var apiKey: String? {
        get { Keychain.get("api-key") }
        set { Keychain.set(newValue, for: "api-key") }
    }
}
