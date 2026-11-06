import Foundation

// Port of upstream src/ios/Providers: ProviderTypes / ProviderInstance / ModelEntry / ModelGroup / ThinkingLevelCatalog.

enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case openAI, openAIResponses, anthropic, gemini, openRouter, xAI, kimiCode
    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "OpenAI 兼容（Chat）"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini（原生）"
        case .openRouter: return "OpenRouter"
        case .xAI: return "xAI"
        case .kimiCode: return "Kimi Code"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI, .openAIResponses: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api"
        case .xAI: return "https://api.x.ai/v1"
        case .kimiCode: return "https://api.kimi.com/coding"
        }
    }

    /// Wire protocol used for chat requests.
    enum Wire { case chat, responses, anthropic, gemini }
    var wire: Wire {
        switch self {
        case .openAI, .openRouter, .xAI, .kimiCode: return .chat
        case .openAIResponses: return .responses
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        }
    }

    var isOpenAIFamily: Bool { wire == .chat || wire == .responses }
}

struct ProviderInstance: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String
    var type: ProviderType
    var isEnabled: Bool = true
    var customBaseURL: String = ""
    var appendV1Suffix: Bool = true
    var azureMode: Bool = false
    var customUserAgent: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), label: String, type: ProviderType, customBaseURL: String = "",
         appendV1Suffix: Bool = true) {
        self.id = id; self.label = label; self.type = type
        self.customBaseURL = customBaseURL; self.appendV1Suffix = appendV1Suffix
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, type, isEnabled, customBaseURL, appendV1Suffix, azureMode, customUserAgent, createdAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Provider"
        type = (try? c.decode(ProviderType.self, forKey: .type)) ?? .openAI
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        customBaseURL = try c.decodeIfPresent(String.self, forKey: .customBaseURL) ?? ""
        appendV1Suffix = try c.decodeIfPresent(Bool.self, forKey: .appendV1Suffix) ?? true
        azureMode = try c.decodeIfPresent(Bool.self, forKey: .azureMode) ?? false
        customUserAgent = try c.decodeIfPresent(String.self, forKey: .customUserAgent) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var keychainAccount: String { id.uuidString }
    var apiKey: String { Keychain.get(keychainAccount) ?? "" }

    var isLocal: Bool {
        let b = effectiveBaseURL
        return b.contains("localhost") || b.contains("127.0.0.1") || b.contains("[::1]")
    }
    var hasCredential: Bool { isLocal || !apiKey.isEmpty }

    /// Base URL after defaults and the `/v1` suffix rule (OpenAI family only).
    var effectiveBaseURL: String {
        var b = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { b = type.defaultBaseURL }
        while b.hasSuffix("/") { b.removeLast() }
        if type.isOpenAIFamily && type != .xAI && appendV1Suffix && !b.hasSuffix("/v1") {
            b += "/v1"
        }
        return b
    }

    /// Instances offered by the "add provider" menu.
    static var presets: [ProviderInstance] {
        [
            ProviderInstance(label: "OpenAI", type: .openAI),
            ProviderInstance(label: "OpenAI Responses", type: .openAIResponses),
            ProviderInstance(label: "Anthropic", type: .anthropic),
            ProviderInstance(label: "Gemini", type: .gemini),
            ProviderInstance(label: "OpenRouter", type: .openRouter),
            ProviderInstance(label: "xAI", type: .xAI),
            ProviderInstance(label: "Kimi Code", type: .kimiCode),
            ProviderInstance(label: "Moonshot（Kimi）", type: .openAI, customBaseURL: "https://api.moonshot.cn"),
            ProviderInstance(label: "DeepSeek", type: .openAI, customBaseURL: "https://api.deepseek.com"),
            ProviderInstance(label: "Ollama（本地）", type: .openAI, customBaseURL: "http://localhost:11434"),
            ProviderInstance(label: "自定义 OpenAI 兼容", type: .openAI, customBaseURL: "https://"),
        ]
    }
}

enum ThinkingLevel: String, Codable, CaseIterable, Identifiable, Comparable {
    case off, low, medium, high, xhigh, max, ultra
    var id: String { rawValue }
    var rank: Int { ThinkingLevel.allCases.firstIndex(of: self)! }
    static func < (a: ThinkingLevel, b: ThinkingLevel) -> Bool { a.rank < b.rank }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "超高"
        case .max: return "最大"
        case .ultra: return "极限"
        }
    }

    /// Wire effort string; `ultra` is client-only and collapses to "max".
    var effort: String? {
        switch self {
        case .off: return nil
        case .ultra: return "max"
        default: return rawValue
        }
    }

    /// Prefix-based ceiling for models without catalog data (ThinkingLevelCatalog.swift).
    static func defaultCeiling(for model: String) -> ThinkingLevel {
        let m = model.lowercased()
        let maxPrefixes = ["gpt-6", "gpt-5.6", "claude-opus-4", "claude-opus-5", "claude-sonnet-5-5",
                           "deepseek-flash", "deepseek-v4"]
        if maxPrefixes.contains(where: { m.hasPrefix($0) || m.contains("/" + $0) }) { return .max }
        if m.hasPrefix("gpt-5.5") || m.contains("/gpt-5.5") { return .xhigh }
        if ["mimo", "agnes", "seed-"].contains(where: { m.contains($0) }) { return .high }
        return .xhigh
    }
}

struct ModelOverrides: Codable, Hashable {
    var displayName: String? = nil
    var maxOutputTokens: Int? = nil
    var contextWindow: Int? = nil
    var supportsReasoning: Bool? = nil
    var supportsImages: Bool? = nil
    var maxThinkingLevel: ThinkingLevel? = nil
    var temperature: Double? = nil
    var topP: Double? = nil
    var customHeaders: [String: String] = [:]
    /// Values are parsed as JSON when possible (numbers, bools, objects), else sent as strings.
    var extraBody: [String: String] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey {
        case displayName, maxOutputTokens, contextWindow, supportsReasoning, supportsImages,
             maxThinkingLevel, temperature, topP, customHeaders, extraBody
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        supportsReasoning = try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages)
        maxThinkingLevel = try? c.decodeIfPresent(ThinkingLevel.self, forKey: .maxThinkingLevel)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        customHeaders = try c.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        extraBody = try c.decodeIfPresent([String: String].self, forKey: .extraBody) ?? [:]
    }

    static let forbiddenHeaders: Set<String> = ["authorization", "api-key", "x-api-key", "anthropic-version",
                                                "content-type", "content-length", "host"]
}

/// Facts about a model, filled from the provider's /models list and models.dev.
struct ModelInfo: Codable, Hashable {
    var name: String? = nil
    var contextWindow: Int? = nil
    var maxOutput: Int? = nil
    var reasoning: Bool? = nil
    var imageInput: Bool? = nil
    var efforts: [String]? = nil
    var costInput: Double? = nil   // USD per 1M tokens
    var costOutput: Double? = nil
}

struct ModelEntry: Codable, Identifiable, Hashable {
    var instanceID: UUID
    var modelID: String
    var info: ModelInfo = ModelInfo()
    var overrides: ModelOverrides = ModelOverrides()
    var isCustom: Bool = false
    var isHidden: Bool = false

    /// Composite key "{instanceId}/{modelId}", same shape as upstream.
    var id: String { "\(instanceID.uuidString)/\(modelID)" }

    init(instanceID: UUID, modelID: String, info: ModelInfo = ModelInfo(), isCustom: Bool = false) {
        self.instanceID = instanceID; self.modelID = modelID; self.info = info; self.isCustom = isCustom
    }

    private enum CodingKeys: String, CodingKey { case instanceID, modelID, info, overrides, isCustom, isHidden }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instanceID = try c.decode(UUID.self, forKey: .instanceID)
        modelID = try c.decode(String.self, forKey: .modelID)
        info = try c.decodeIfPresent(ModelInfo.self, forKey: .info) ?? ModelInfo()
        overrides = try c.decodeIfPresent(ModelOverrides.self, forKey: .overrides) ?? ModelOverrides()
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }

    var displayName: String {
        if let d = overrides.displayName, !d.isEmpty { return d }
        return info.name ?? modelID
    }
    var supportsReasoning: Bool { overrides.supportsReasoning ?? info.reasoning ?? true }
    var supportsImages: Bool { overrides.supportsImages ?? info.imageInput ?? true }
    var contextWindow: Int? { overrides.contextWindow ?? info.contextWindow }
    var maxOutputTokens: Int? { overrides.maxOutputTokens }

    var thinkingCeiling: ThinkingLevel {
        if let m = overrides.maxThinkingLevel { return m }
        if let e = info.efforts, !e.isEmpty {
            let levels = e.compactMap { ThinkingLevel(rawValue: $0) }
            if let top = levels.max() { return top }
        }
        return ThinkingLevel.defaultCeiling(for: modelID)
    }

    /// Requested level clamped to what the model supports; nil = don't send anything.
    func effectiveThinking(_ requested: ThinkingLevel?) -> ThinkingLevel? {
        guard let r = requested, supportsReasoning else { return nil }
        if r == .off { return .off }
        var level = min(r, thinkingCeiling)
        // Clamp to the nearest declared level when the catalog lists them (e.g. DeepSeek xhigh → high).
        if let e = info.efforts, !e.isEmpty {
            let declared = e.compactMap { ThinkingLevel(rawValue: $0) }.filter { $0 != .off }.sorted()
            if !declared.isEmpty && !declared.contains(level) {
                level = declared.last(where: { $0 <= level }) ?? declared.first!
            }
        }
        return level
    }
}

enum GroupStrategy: String, Codable, CaseIterable, Identifiable {
    case fallback, loadBalance
    var id: String { rawValue }
    var label: String { self == .fallback ? "按顺序回退" : "负载均衡" }
}

enum FallbackPolicy: String, Codable, CaseIterable, Identifiable {
    case limited, always
    var id: String { rawValue }
    var label: String { self == .limited ? "仅服务方错误时回退" : "任何错误都回退" }
}

struct ModelGroup: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var members: [String] = []          // ModelEntry.id, ordered
    var strategy: GroupStrategy = .fallback
    var fallbackPolicy: FallbackPolicy = .limited
    var defaultThinkingLevel: ThinkingLevel? = nil
    var contextLimitTokens: Int? = nil

    init(id: UUID = UUID(), name: String, members: [String] = []) {
        self.id = id; self.name = name; self.members = members
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, members, strategy, fallbackPolicy, defaultThinkingLevel, contextLimitTokens
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "分组"
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        strategy = (try? c.decode(GroupStrategy.self, forKey: .strategy)) ?? .fallback
        fallbackPolicy = (try? c.decode(FallbackPolicy.self, forKey: .fallbackPolicy)) ?? .limited
        defaultThinkingLevel = try? c.decodeIfPresent(ThinkingLevel.self, forKey: .defaultThinkingLevel)
        contextLimitTokens = try c.decodeIfPresent(Int.self, forKey: .contextLimitTokens)
    }
}

struct TokenUsage: Codable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                   cacheWrite: a.cacheWrite + b.cacheWrite, reasoning: a.reasoning + b.reasoning)
    }
}

// MARK: - Routing (ModelGroupRouter.swift)

enum ModelRouter {
    /// Stable FNV-1a hash; Swift's hashValue is re-salted per launch.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// Ordered candidates for one turn: the chosen first member, then the rest wrapping around.
    static func candidates(group: ModelGroup, sessionKey: String,
                           isAvailable: (String) -> Bool) -> [String] {
        let avail = group.members.filter(isAvailable)
        guard !avail.isEmpty else { return [] }
        let start: Int
        switch group.strategy {
        case .fallback: start = 0
        case .loadBalance: start = Int(stableHash(sessionKey) % UInt64(avail.count))
        }
        return Array(avail[start...] + avail[..<start])
    }

    /// Whether an error should move on to the next member (true) or be retried on the same one (false).
    static func shouldFallback(_ error: LLMError, policy: FallbackPolicy) -> Bool {
        switch policy {
        case .always: return true
        case .limited: return !error.isTransient
        }
    }
}
