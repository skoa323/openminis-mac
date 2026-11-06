import Foundation

// Gemini native :streamGenerateContent (SSE). Port of upstream Gemini/GeminiProvider + GeminiWireFormat
// and the Gemini branch of ThinkingRuleResolver.

enum GeminiWire {
    /// generationConfig.thinkingConfig for a model and level; nil = omit the field.
    static func thinkingConfig(model: String, level: ThinkingLevel?) -> [String: Any]? {
        guard let level else { return nil }
        let m = model.lowercased()
        for suffix in ["-tts", "-image", "-embedding", "-vision"] where m.contains(suffix) { return nil }

        if m.contains("gemini-3") {
            let v: String
            switch level {
            case .off:
                // Flash below x.7 supports "minimal"; others bottom out at "low".
                var minorOK = false
                if m.contains("flash"), let r = m.range(of: "gemini-3.") {
                    let digits = m[r.upperBound...].prefix(while: { $0.isNumber })
                    minorOK = (Int(digits) ?? 0) < 7
                } else if m.contains("flash") {
                    minorOK = true
                }
                v = minorOK ? "minimal" : "low"
                return ["thinkingLevel": v]
            case .low: v = "low"
            case .medium: v = "medium"
            default: v = "high"
            }
            return ["thinkingLevel": v, "includeThoughts": true]
        }

        let isPro = m.contains("2.5-pro")
        let isLite = m.contains("flash-lite")
        if level == .off {
            if isLite { return nil }
            return ["thinkingBudget": isPro ? 128 : 0]
        }
        let budgets: [Int]
        if isPro { budgets = [2048, 8192, 16384, 32768] } else { budgets = [1024, 4096, 8192, 16384] }
        let b: Int
        switch level {
        case .low: b = budgets[0]
        case .medium: b = budgets[1]
        case .high: b = budgets[2]
        default: b = budgets[3]
        }
        return ["thinkingBudget": b, "includeThoughts": true]
    }

    static func streamURL(_ ctx: RequestContext) -> URL? {
        var b = ctx.base
        while b.hasSuffix("/") { b.removeLast() }
        let model = ctx.model.hasPrefix("models/") ? String(ctx.model.dropFirst(7)) : ctx.model
        return URL(string: "\(b)/models/\(model):streamGenerateContent?alt=sse")
    }

    static func body(system: String, messages: [ChatMessage], tools: [ToolSpec], ctx: RequestContext) -> [String: Any] {
        var contents: [[String: Any]] = []
        // Gemini matches function responses by name; remember which call id had which name.
        var callNames: [String: String] = [:]

        func append(role: String, parts: [[String: Any]]) {
            guard !parts.isEmpty else { return }
            if let last = contents.last, (last["role"] as? String) == role,
               var existing = last["parts"] as? [[String: Any]] {
                existing.append(contentsOf: parts)
                contents[contents.count - 1]["parts"] = existing
            } else {
                contents.append(["role": role, "parts": parts])
            }
        }

        for m in messages {
            switch m.role {
            case .user:
                let (text, imgs) = LLMUtil.userParts(m, ctx)
                var parts: [[String: Any]] = imgs.map { ["inlineData": ["mimeType": "image/jpeg", "data": $0]] }
                if !text.isEmpty || parts.isEmpty { parts.append(["text": text.isEmpty ? " " : text]) }
                append(role: "user", parts: parts)
            case .assistant:
                var parts: [[String: Any]] = []
                if !m.content.isEmpty { parts.append(["text": m.content]) }
                for tc in m.toolCalls {
                    callNames[tc.id] = tc.name
                    let args = (LLMUtil.jsonObject(tc.arguments) as? [String: Any]) ?? [:]
                    var p: [String: Any] = ["functionCall": ["name": tc.name, "args": args]]
                    if let sig = tc.thoughtSignature, !sig.isEmpty { p["thoughtSignature"] = sig }
                    parts.append(p)
                }
                append(role: "model", parts: parts)
            case .tool:
                let name = m.toolName ?? callNames[m.toolCallId ?? ""] ?? "tool"
                let resp: [String: Any] = m.isError ? ["error": m.content] : ["output": m.content]
                append(role: "user", parts: [["functionResponse": ["name": name, "response": resp]]])
            case .system:
                break
            }
        }

        var gen: [String: Any] = [:]
        if let mt = ctx.entry.maxOutputTokens { gen["maxOutputTokens"] = mt }
        if let t = ctx.entry.overrides.temperature { gen["temperature"] = t }
        if let p = ctx.entry.overrides.topP { gen["topP"] = p }
        if let tc = thinkingConfig(model: ctx.model, level: ctx.thinking) { gen["thinkingConfig"] = tc }

        var b: [String: Any] = [
            "contents": contents,
            "systemInstruction": ["parts": [["text": system]]],
        ]
        if !gen.isEmpty { b["generationConfig"] = gen }
        if !tools.isEmpty {
            let decls = tools.map { t -> [String: Any] in
                ["name": t.name, "description": t.description, "parameters": t.parameters]
            }
            b["tools"] = [["functionDeclarations": decls]]
        }
        LLMUtil.mergeExtraBody(&b, ctx)
        return b
    }
}

struct GeminiClient: LLMClient {
    let ctx: RequestContext

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        LLMUtil.makeStream { cont in
            guard let url = GeminiWire.streamURL(ctx) else { throw LLMError(message: "Base URL 无效：\(ctx.base)") }
            var req = try LLMUtil.postJSON(url, GeminiWire.body(system: system, messages: messages, tools: tools, ctx: ctx), ctx)
            req.setValue(ctx.apiKey, forHTTPHeaderField: "x-goog-api-key")

            let bytes = try await LLMUtil.openSSE(req)
            var usage: TokenUsage? = nil

            for try await payload in LLMUtil.dataLines(bytes) {
                guard let obj = LLMUtil.jsonObject(payload) as? [String: Any] else { continue }
                if let err = obj["error"] as? [String: Any] {
                    let code = LLMUtil.int(err["code"])
                    throw LLMError.http(code == 0 ? 400 : code, body: (err["message"] as? String) ?? "\(err)")
                }
                if let um = obj["usageMetadata"] as? [String: Any] {
                    var u = TokenUsage()
                    u.input = LLMUtil.int(um["promptTokenCount"])
                    u.reasoning = LLMUtil.int(um["thoughtsTokenCount"])
                    u.output = LLMUtil.int(um["candidatesTokenCount"]) + u.reasoning
                    u.cacheRead = LLMUtil.int(um["cachedContentTokenCount"])
                    usage = u   // cumulative; keep the latest
                }
                guard let cands = obj["candidates"] as? [[String: Any]],
                      let content = cands.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { continue }
                for p in parts {
                    if let fc = p["functionCall"] as? [String: Any] {
                        let name = (fc["name"] as? String) ?? ""
                        let args = fc["args"] ?? [String: Any]()
                        let argStr = (try? JSONSerialization.data(withJSONObject: args))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        let id = "call_\(UUID().uuidString.prefix(12))"
                        cont.yield(.toolCall(ToolCall(id: id, name: name, arguments: argStr,
                                                      thoughtSignature: p["thoughtSignature"] as? String)))
                    } else if let text = p["text"] as? String, !text.isEmpty {
                        if (p["thought"] as? Bool) == true { cont.yield(.reasoning(text)) }
                        else { cont.yield(.text(text)) }
                    }
                }
            }
            if let usage { cont.yield(.usage(usage)) }
        }
    }
}
