import Foundation

/// Which model handles which job. All default to DeepSeek's `deepseek-flash` (V4.1 Flash, vision-capable).
public struct ModelConfig: Codable, Sendable, Hashable {
    /// Main conversation, including photos and tool use.
    public var chatModel: String
    /// Background jobs: compaction, daily reflection. Run without thinking.
    public var utilityModel: String
    public var chatEffort: ReasoningEffort
    public var reflectionEffort: ReasoningEffort

    public init(chatModel: String = "deepseek-flash", utilityModel: String = "deepseek-flash",
                chatEffort: ReasoningEffort = .low, reflectionEffort: ReasoningEffort = .off) {
        self.chatModel = chatModel
        self.utilityModel = utilityModel
        self.chatEffort = chatEffort
        self.reflectionEffort = reflectionEffort
    }

    public static let deepSeekDefault = ModelConfig()
}
