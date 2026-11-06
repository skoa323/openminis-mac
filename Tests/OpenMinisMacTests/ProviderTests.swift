import XCTest
@testable import OpenMinisMac

final class ProviderTests: XCTestCase {
    private func ctx(_ type: ProviderType, model: String, base: String = "", thinking: ThinkingLevel? = nil,
                     reasoning: Bool? = nil) -> RequestContext {
        let inst = ProviderInstance(label: "t", type: type, customBaseURL: base)
        var e = ModelEntry(instanceID: inst.id, modelID: model)
        e.info.reasoning = reasoning
        return RequestContext(instance: inst, entry: e, apiKey: "k", thinking: thinking)
    }

    // MARK: URL rules

    func testV1SuffixRules() {
        XCTAssertEqual(ProviderInstance(label: "", type: .openAI).effectiveBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(ProviderInstance(label: "", type: .openAI, customBaseURL: "https://x.com/v1/").effectiveBaseURL,
                       "https://x.com/v1")
        XCTAssertEqual(ProviderInstance(label: "", type: .xAI).effectiveBaseURL, "https://api.x.ai/v1")
        XCTAssertEqual(ProviderInstance(label: "", type: .anthropic).effectiveBaseURL, "https://api.anthropic.com")
        var noV1 = ProviderInstance(label: "", type: .openAI, customBaseURL: "https://gw.example.com/openai")
        noV1.appendV1Suffix = false
        XCTAssertEqual(noV1.effectiveBaseURL, "https://gw.example.com/openai")
    }

    func testLocalNeedsNoKey() {
        let i = ProviderInstance(label: "", type: .openAI, customBaseURL: "http://localhost:11434")
        XCTAssertTrue(i.isLocal)
    }

    // MARK: Routing

    func testFallbackOrderAndAvailability() {
        let g = ModelGroup(name: "g", members: ["a", "b", "c"])
        let c = ModelRouter.candidates(group: g, sessionKey: "s", isAvailable: { $0 != "a" })
        XCTAssertEqual(c, ["b", "c"])
    }

    func testLoadBalanceIsStableAndWraps() {
        var g = ModelGroup(name: "g", members: ["a", "b", "c"])
        g.strategy = .loadBalance
        let c1 = ModelRouter.candidates(group: g, sessionKey: "session-1", isAvailable: { _ in true })
        let c2 = ModelRouter.candidates(group: g, sessionKey: "session-1", isAvailable: { _ in true })
        XCTAssertEqual(c1, c2)
        XCTAssertEqual(Set(c1), ["a", "b", "c"])
        XCTAssertEqual(ModelRouter.stableHash("abc"), 0xe71fa2190541574b)
    }

    func testErrorPolicy() {
        let transient = LLMError.http(503, body: "")
        let auth = LLMError.http(401, body: "")
        XCTAssertFalse(ModelRouter.shouldFallback(transient, policy: .limited))
        XCTAssertTrue(ModelRouter.shouldFallback(auth, policy: .limited))
        XCTAssertTrue(ModelRouter.shouldFallback(transient, policy: .always))
        XCTAssertEqual(LLMError.http(429, body: "").kind, .rateLimited)
    }

    // MARK: Thinking

    func testThinkingClampToDeclaredEfforts() {
        var e = ModelEntry(instanceID: UUID(), modelID: "deepseek-x")
        e.info.reasoning = true
        e.info.efforts = ["low", "medium", "high"]
        XCTAssertEqual(e.effectiveThinking(.xhigh), .high)
        XCTAssertEqual(e.effectiveThinking(.off), .off)
        e.info.reasoning = false
        XCTAssertNil(e.effectiveThinking(.high))
    }

    func testCeilingCatalog() {
        XCTAssertEqual(ThinkingLevel.defaultCeiling(for: "gpt-5.5-mini"), .xhigh)
        XCTAssertEqual(ThinkingLevel.defaultCeiling(for: "claude-opus-4-6"), .max)
        XCTAssertEqual(ThinkingLevel.ultra.effort, "max")
        XCTAssertNil(ThinkingLevel.off.effort)
    }

    func testOpenAIReasoningEffort() {
        let b = OpenAIWire.chatBody(system: "s", messages: [ChatMessage(role: .user, content: "hi")], tools: [],
                                    ctx: ctx(.openAI, model: "o3", thinking: .high, reasoning: true))
        XCTAssertEqual(b["reasoning_effort"] as? String, "high")
        let plain = OpenAIWire.chatBody(system: "s", messages: [ChatMessage(role: .user, content: "hi")], tools: [],
                                        ctx: ctx(.openAI, model: "gpt-4o", thinking: .high, reasoning: false))
        XCTAssertNil(plain["reasoning_effort"])
    }

    func testAnthropicAdaptiveVsBudget() {
        XCTAssertTrue(AnthropicWire.isAdaptive("claude-opus-4-6"))
        XCTAssertTrue(AnthropicWire.isAdaptive("claude-sonnet-5-5"))
        XCTAssertFalse(AnthropicWire.isAdaptive("claude-sonnet-4-5"))
        XCTAssertEqual(AnthropicWire.budget(.low, maxTokens: 64000), 8192)
        XCTAssertLessThan(AnthropicWire.budget(.max, maxTokens: 64000), 64000)

        let adaptive = AnthropicWire.body(system: "s", messages: [ChatMessage(role: .user, content: "hi")], tools: [],
                                          ctx: ctx(.anthropic, model: "claude-opus-4-6", thinking: .xhigh, reasoning: true))
        XCTAssertEqual((adaptive["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual((adaptive["output_config"] as? [String: Any])?["effort"] as? String, "max")

        let budget = AnthropicWire.body(system: "s", messages: [ChatMessage(role: .user, content: "hi")], tools: [],
                                        ctx: ctx(.anthropic, model: "claude-sonnet-4-5", thinking: .medium, reasoning: true))
        let t = budget["thinking"] as? [String: Any]
        XCTAssertEqual(t?["type"] as? String, "enabled")
        XCTAssertEqual(t?["budget_tokens"] as? Int, 32768)
        XCTAssertLessThan(t?["budget_tokens"] as? Int ?? .max, budget["max_tokens"] as? Int ?? 0)
    }

    func testGeminiThinkingConfig() {
        XCTAssertEqual(GeminiWire.thinkingConfig(model: "gemini-3-pro", level: .high)?["thinkingLevel"] as? String, "high")
        XCTAssertEqual(GeminiWire.thinkingConfig(model: "gemini-2.5-pro", level: .medium)?["thinkingBudget"] as? Int, 8192)
        XCTAssertEqual(GeminiWire.thinkingConfig(model: "gemini-2.5-flash", level: .off)?["thinkingBudget"] as? Int, 0)
        XCTAssertNil(GeminiWire.thinkingConfig(model: "gemini-2.5-flash-tts", level: .high))
    }

    func testGeminiBodyMapsToolRoundTrip() {
        let call = ToolCall(id: "c1", name: "shell", arguments: "{\"command\":\"ls\"}", thoughtSignature: "sig")
        let msgs = [
            ChatMessage(role: .user, content: "list"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(role: .tool, content: "a.txt", toolCallId: "c1", toolName: "shell"),
        ]
        let b = GeminiWire.body(system: "s", messages: msgs, tools: [], ctx: ctx(.gemini, model: "gemini-3-pro"))
        let contents = b["contents"] as? [[String: Any]] ?? []
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
        let fc = (contents[1]["parts"] as? [[String: Any]])?.first
        XCTAssertNotNil(fc?["functionCall"])
        XCTAssertEqual(fc?["thoughtSignature"] as? String, "sig")
        let fr = (contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any]
        XCTAssertEqual(fr?["name"] as? String, "shell")
    }

    func testUsageParsing() {
        let u = OpenAIWire.usage(["prompt_tokens": 100, "completion_tokens": 20,
                                  "prompt_tokens_details": ["cached_tokens": 40]])
        XCTAssertEqual(u.input, 100); XCTAssertEqual(u.output, 20); XCTAssertEqual(u.cacheRead, 40)
    }

    // MARK: Migration

    func testLegacySettingsMigrate() throws {
        let pid = UUID()
        let json = """
        {"profiles":[{"id":"\(pid.uuidString)","name":"DeepSeek","kind":"openai",
          "baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat"}],
         "activeProfileID":"\(pid.uuidString)","customPrompt":"x","confirmShell":false}
        """
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.instances.first?.id, pid)               // keychain key preserved
        XCTAssertEqual(s.instances.first?.effectiveBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(s.entries.first?.modelID, "deepseek-chat")
        XCTAssertEqual(s.groups.first?.members, s.entries.map(\.id))
        XCTAssertEqual(s.customPrompt, "x")
        XCTAssertFalse(s.confirmShell)

        // Re-encode / decode keeps the new shape.
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again.instances.count, 1)
        XCTAssertEqual(again.groups.first?.members.count, 1)
    }

    func testInitialSettingsHaveDefaultGroup() {
        let s = AppSettings.initial
        XCTAssertFalse(s.instances.isEmpty)
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(s.groups.first?.members.count, s.entries.count)
    }

    func testModelsListParsing() {
        let gem = ModelCatalog.parse(["models": [
            ["name": "models/gemini-2.5-pro", "inputTokenLimit": 1048576, "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]],
        ]], type: .gemini)
        XCTAssertEqual(gem.map(\.id), ["gemini-2.5-pro"])
        XCTAssertEqual(gem.first?.info.contextWindow, 1048576)

        let oai = ModelCatalog.parse(["data": [["id": "gpt-4o"], ["id": ""]]], type: .openAI)
        XCTAssertEqual(oai.map(\.id), ["gpt-4o"])
    }

    func testRetryLadder() {
        let http503 = LLMError.http(503, body: "")
        let net = LLMError(kind: .network, message: "x")
        XCTAssertEqual(ModelRouter.retryDelays(for: http503, hasFallbackTarget: true), [2, 5])
        XCTAssertEqual(ModelRouter.retryDelays(for: http503, hasFallbackTarget: false), [3, 5, 10, 15, 30])
        XCTAssertEqual(ModelRouter.retryDelays(for: net, hasFallbackTarget: true), [3, 5, 10, 15, 30])
    }
}
