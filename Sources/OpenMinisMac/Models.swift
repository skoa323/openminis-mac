import Foundation

enum Role: String, Codable {
    case system, user, assistant, tool
}

struct ToolCall: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var arguments: String
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: Role
    var content: String
    var toolCalls: [ToolCall] = []
    var toolCallId: String? = nil
    var toolName: String? = nil
    /// For assistant messages: a local error notice, excluded from API history.
    /// For tool messages: the tool reported a failure.
    var isError: Bool = false
    var date: Date = Date()
}

struct Conversation: Codable, Identifiable, Hashable {
    static let defaultTitle = "新对话"
    var id: UUID = UUID()
    var title: String = Conversation.defaultTitle
    var messages: [ChatMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openai, anthropic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openai: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }
}

struct ProviderProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var model: String

    /// Fresh copies (new UUIDs) every call.
    static var presets: [ProviderProfile] {
        [
            ProviderProfile(name: "OpenAI", kind: .openai, baseURL: "https://api.openai.com/v1", model: "gpt-4o"),
            ProviderProfile(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-5"),
            ProviderProfile(name: "DeepSeek", kind: .openai, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
            ProviderProfile(name: "Gemini", kind: .openai, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash"),
            ProviderProfile(name: "OpenRouter", kind: .openai, baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o"),
            ProviderProfile(name: "Ollama（本地）", kind: .openai, baseURL: "http://localhost:11434/v1", model: "qwen2.5"),
            ProviderProfile(name: "自定义", kind: .openai, baseURL: "", model: ""),
        ]
    }
}

struct AppSettings: Codable {
    var profiles: [ProviderProfile] = []
    var activeProfileID: UUID? = nil
    var customPrompt: String = ""
    var workspacePath: String = NSHomeDirectory() + "/OpenMinis"
    var confirmShell: Bool = true
    var maxIterations: Int = 40

    static var initial: AppSettings {
        var s = AppSettings()
        s.profiles = ProviderProfile.presets.filter { !$0.baseURL.isEmpty }
        s.activeProfileID = s.profiles.first?.id
        return s
    }
}
