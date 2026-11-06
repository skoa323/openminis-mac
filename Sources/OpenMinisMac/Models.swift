import Foundation

enum Role: String, Codable {
    case system, user, assistant, tool
}

struct ToolCall: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var arguments: String
    /// Gemini 3 requires the function call's thought signature to be echoed back.
    var thoughtSignature: String? = nil

    init(id: String, name: String, arguments: String, thoughtSignature: String? = nil) {
        self.id = id; self.name = name; self.arguments = arguments; self.thoughtSignature = thoughtSignature
    }
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
    /// Model's reasoning / thinking text (assistant only).
    var reasoning: String = ""
    /// Anthropic thinking-block signature, replayed with tool-use turns.
    var reasoningSignature: String? = nil
    /// Attached image file names inside `Attachments.dir` (user only).
    var images: [String] = []
    /// Token usage reported for this assistant turn.
    var usage: TokenUsage? = nil
    /// "Provider · model" that produced this assistant turn.
    var modelLabel: String? = nil

    init(id: UUID = UUID(), role: Role, content: String, toolCalls: [ToolCall] = [],
         toolCallId: String? = nil, toolName: String? = nil, isError: Bool = false,
         date: Date = Date(), reasoning: String = "", images: [String] = []) {
        self.id = id; self.role = role; self.content = content; self.toolCalls = toolCalls
        self.toolCallId = toolCallId; self.toolName = toolName; self.isError = isError
        self.date = date; self.reasoning = reasoning; self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, toolCalls, toolCallId, toolName, isError, date, reasoning,
             reasoningSignature, images, usage, modelLabel
    }

    /// Tolerant decoding so conversations saved by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        reasoningSignature = try c.decodeIfPresent(String.self, forKey: .reasoningSignature)
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        usage = try? c.decodeIfPresent(TokenUsage.self, forKey: .usage)
        modelLabel = try c.decodeIfPresent(String.self, forKey: .modelLabel)
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    static let defaultTitle = "新对话"
    var id: UUID = UUID()
    var title: String = Conversation.defaultTitle
    var messages: [ChatMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Per-conversation overrides; nil = follow the global defaults.
    var groupID: UUID? = nil
    var thinkingLevel: ThinkingLevel? = nil
    /// Session management (upstream ChatSession.pinnedAt / folderId / category).
    var pinnedAt: Date? = nil
    var folderID: UUID? = nil
    var icon: String? = nil

    var isPinned: Bool { pinnedAt != nil }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, groupID, thinkingLevel, pinnedAt, folderID, icon
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? Conversation.defaultTitle
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        thinkingLevel = try? c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }
}

/// Sidebar folder (upstream ChatFolder; called "Group" in the iOS UI).
struct ChatFolder: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var icon: String? = nil
    var pinnedAt: Date? = nil
    var desc: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String, icon: String? = nil) { self.name = name; self.icon = icon }

    private enum CodingKeys: String, CodingKey { case id, name, icon, pinnedAt, desc, createdAt, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "分组"
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// v0.1 settings shape, kept only to migrate old installs.
private struct LegacyProfile: Decodable {
    var id: UUID
    var name: String
    var kind: String
    var baseURL: String
    var model: String
}

struct AppSettings: Codable {
    var instances: [ProviderInstance] = []
    var entries: [ModelEntry] = []
    var groups: [ModelGroup] = []
    var activeGroupID: UUID? = nil
    var defaultThinkingLevel: ThinkingLevel = .medium
    var customPrompt: String = ""
    var workspacePath: String = NSHomeDirectory() + "/OpenMinis"
    var confirmShell: Bool = true
    var maxIterations: Int = 40
    var autoTitle: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case instances, entries, groups, activeGroupID, defaultThinkingLevel,
             customPrompt, workspacePath, confirmShell, maxIterations, autoTitle,
             profiles, activeProfileID // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instances = try c.decodeIfPresent([ProviderInstance].self, forKey: .instances) ?? []
        entries = try c.decodeIfPresent([ModelEntry].self, forKey: .entries) ?? []
        groups = try c.decodeIfPresent([ModelGroup].self, forKey: .groups) ?? []
        activeGroupID = try c.decodeIfPresent(UUID.self, forKey: .activeGroupID)
        defaultThinkingLevel = (try? c.decode(ThinkingLevel.self, forKey: .defaultThinkingLevel)) ?? .medium
        customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath) ?? NSHomeDirectory() + "/OpenMinis"
        confirmShell = try c.decodeIfPresent(Bool.self, forKey: .confirmShell) ?? true
        maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 40
        autoTitle = try c.decodeIfPresent(Bool.self, forKey: .autoTitle) ?? true

        if instances.isEmpty, let legacy = try? c.decodeIfPresent([LegacyProfile].self, forKey: .profiles), !legacy.isEmpty {
            let activeLegacy = try? c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
            migrate(legacy, active: activeLegacy ?? nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instances, forKey: .instances)
        try c.encode(entries, forKey: .entries)
        try c.encode(groups, forKey: .groups)
        try c.encodeIfPresent(activeGroupID, forKey: .activeGroupID)
        try c.encode(defaultThinkingLevel, forKey: .defaultThinkingLevel)
        try c.encode(customPrompt, forKey: .customPrompt)
        try c.encode(workspacePath, forKey: .workspacePath)
        try c.encode(confirmShell, forKey: .confirmShell)
        try c.encode(maxIterations, forKey: .maxIterations)
        try c.encode(autoTitle, forKey: .autoTitle)
    }

    /// Each old profile becomes an instance with the SAME id (so its Keychain key keeps working),
    /// one model entry, and membership in a default group (active profile first).
    private mutating func migrate(_ legacy: [LegacyProfile], active: UUID?) {
        var memberIDs: [String] = []
        for p in legacy {
            var inst = ProviderInstance(id: p.id, label: p.name, type: p.kind == "anthropic" ? .anthropic : .openAI)
            var base = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            inst.customBaseURL = base
            // Old OpenAI-style URLs were used verbatim (".../v1", ".../v1beta/openai"): never append again.
            inst.appendV1Suffix = false
            instances.append(inst)
            let model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                let e = ModelEntry(instanceID: inst.id, modelID: model, isCustom: true)
                entries.append(e)
                if p.id == active { memberIDs.insert(e.id, at: 0) } else { memberIDs.append(e.id) }
            }
        }
        let g = ModelGroup(name: "默认", members: memberIDs)
        groups = [g]
        activeGroupID = g.id
    }

    /// Fresh install: common providers with a starter model each, all in one fallback group.
    static var initial: AppSettings {
        var s = AppSettings()
        let starters: [(ProviderInstance, String)] = [
            (ProviderInstance(label: "OpenAI", type: .openAI), "gpt-4o"),
            (ProviderInstance(label: "Anthropic", type: .anthropic), "claude-sonnet-4-5"),
            (ProviderInstance(label: "Gemini", type: .gemini), "gemini-2.5-flash"),
            (ProviderInstance(label: "DeepSeek", type: .openAI, customBaseURL: "https://api.deepseek.com"), "deepseek-chat"),
            (ProviderInstance(label: "Moonshot（Kimi）", type: .openAI, customBaseURL: "https://api.moonshot.cn"), "kimi-k2-0905-preview"),
            (ProviderInstance(label: "OpenRouter", type: .openRouter), "openai/gpt-4o"),
            (ProviderInstance(label: "Ollama（本地）", type: .openAI, customBaseURL: "http://localhost:11434"), "qwen2.5"),
        ]
        var members: [String] = []
        for (inst, model) in starters {
            s.instances.append(inst)
            let e = ModelEntry(instanceID: inst.id, modelID: model, isCustom: true)
            s.entries.append(e)
            members.append(e.id)
        }
        let g = ModelGroup(name: "默认", members: members)
        s.groups = [g]
        s.activeGroupID = g.id
        return s
    }
}
