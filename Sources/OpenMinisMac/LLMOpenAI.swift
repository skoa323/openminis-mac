import Foundation

// OpenAI Chat Completions (OpenAI, DeepSeek, Moonshot, OpenRouter, xAI, Kimi Code, Ollama…)
// and OpenAI Responses API. Port of upstream OpenAI/OpenAIProvider + OpenAIAgentProvider.

enum OpenAIWire {
    /// Known reasoning families when the catalog has no data; avoids 400s on gpt-4o etc.
    static func looksLikeReasoningModel(_ model: String) -> Bool {
        let m = model.lowercased()
        let hints = ["o1", "o3", "o4", "gpt-5", "gpt-6", "deepseek-r", "deepseek-reasoner", "deepseek-v4",
                     "kimi-k2-thinking", "kimi-k3", "grok-3-mini", "grok-4", "qwq", "qwen3", "glm-4.5", "glm-5",
                     "claude-opus-4", "claude-sonnet-4", "claude-opus-5", "claude-sonnet-5", "gemini-2.5", "gemini-3"]
        let last = m.split(separator: "/").last.map(String.init) ?? m
        return hints.contains { last.hasPrefix($0) }
    }

    static func sendsReasoning(_ ctx: RequestContext) -> Bool {
        if let o = ctx.entry.overrides.supportsReasoning { return o }
        if let i = ctx.entry.info.reasoning { return i }
        return looksLikeReasoningModel(ctx.model)
    }

    static func isMistral(_ ctx: RequestContext) -> Bool { ctx.base.contains("mistral.ai") }

    static func chatURL(_ ctx: RequestContext) -> URL? {
        var s = ctx.base + "/chat/completions"
        if ctx.instance.azureMode && !s.contains("api-version=") { s += "?api-version=2024-10-21" }
        return URL(string: s)
    }

    static func auth(_ req: inout URLRequest, _ ctx: RequestContext) {
        guard !ctx.apiKey.isEmpty else { return }
        if ctx.instance.azureMode {
            req.setValue(ctx.apiKey, forHTTPHeaderField: "api-key")
        } else {
            req.setValue("Bearer \(ctx.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if ctx.instance.type == .openRouter {
            req.setValue("https://github.com/skoa323/openminis-mac", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("OpenMinis Mac", forHTTPHeaderField: "X-Title")
        }
    }

    static func chatBody(system: String, messages: [ChatMessage], tools: [ToolSpec], ctx: RequestContext) -> [String: Any] {
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user:
                let (text, imgs) = LLMUtil.userParts(m, ctx)
                if imgs.isEmpty {
                    msgs.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                    for b64 in imgs {
                        let iu: [String: Any] = ["url": "data:image/jpeg;base64,\(b64)"]
                        parts.append(["type": "image_url", "image_url": iu])
                    }
                    msgs.append(["role": "user", "content": parts])
                }
            case .assistant:
                var d: [String: Any] = ["role": "assistant"]
                d["content"] = m.content.isEmpty ? NSNull() : m.content
                if !m.toolCalls.isEmpty {
                    d["tool_calls"] = m.toolCalls.map { tc -> [String: Any] in
                        let fn: [String: Any] = ["name": tc.name, "arguments": tc.arguments]
                        return ["id": tc.id, "type": "function", "function": fn]
                    }
                    // Thinking models (Kimi, DeepSeek) expect their reasoning back alongside tool calls.
                    if !m.reasoning.isEmpty { d["reasoning_content"] = m.reasoning }
                }
                msgs.append(d)
            case .tool:
                msgs.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.content])
            case .system:
                break
            }
        }
        var b: [String: Any] = ["model": ctx.model, "messages": msgs, "stream": true]
        let compat = ctx.instance.type == .openRouter || isMistral(ctx)
        if !isMistral(ctx) { b["stream_options"] = ["include_usage": true] }
        if let mt = ctx.entry.maxOutputTokens {
            b[compat || ctx.instance.type != .openAI ? "max_tokens" : "max_completion_tokens"] = mt
        }
        if let t = ctx.entry.overrides.temperature { b["temperature"] = t }
        if let p = ctx.entry.overrides.topP { b["top_p"] = p }
        if let level = ctx.thinking, level != .off, let effort = level.effort,
           sendsReasoning(ctx), !isMistral(ctx) {
            if ctx.instance.type == .openRouter {
                b["reasoning"] = ["effort": effort]
            } else {
                b["reasoning_effort"] = effort
            }
        }
        if !tools.isEmpty {
            b["tools"] = tools.map { t -> [String: Any] in
                let fn: [String: Any] = ["name": t.name, "description": t.description, "parameters": t.parameters]
                return ["type": "function", "function": fn]
            }
        }
        LLMUtil.mergeExtraBody(&b, ctx)
        return b
    }

    static func usage(_ u: [String: Any]) -> TokenUsage {
        var t = TokenUsage()
        t.input = LLMUtil.int(u["prompt_tokens"] ?? u["input_tokens"])
        t.output = LLMUtil.int(u["completion_tokens"] ?? u["output_tokens"])
        if let d = (u["prompt_tokens_details"] ?? u["input_tokens_details"]) as? [String: Any] {
            t.cacheRead = LLMUtil.int(d["cached_tokens"])
        } else {
            t.cacheRead = LLMUtil.int(u["prompt_cache_hit_tokens"] ?? u["cached_tokens"])
        }
        if let d = (u["completion_tokens_details"] ?? u["output_tokens_details"]) as? [String: Any] {
            t.reasoning = LLMUtil.int(d["reasoning_tokens"])
        }
        return t
    }
}

struct OpenAIChatClient: LLMClient {
    let ctx: RequestContext

    private final class PartialCall { var id = ""; var name = ""; var args = "" }

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        LLMUtil.makeStream { cont in
            guard let url = OpenAIWire.chatURL(ctx) else { throw LLMError(message: "Base URL 无效：\(ctx.base)") }
            var req = try LLMUtil.postJSON(url, OpenAIWire.chatBody(system: system, messages: messages, tools: tools, ctx: ctx), ctx)
            OpenAIWire.auth(&req, ctx)

            let bytes = try await LLMUtil.openSSE(req)
            var partials: [Int: PartialCall] = [:]
            var lastUsage: TokenUsage?

            for try await payload in LLMUtil.dataLines(bytes) {
                if payload == "[DONE]" { break }
                guard let obj = LLMUtil.jsonObject(payload) as? [String: Any] else { continue }
                if let err = obj["error"] as? [String: Any] {
                    throw LLMError(kind: .providerError, message: (err["message"] as? String) ?? "\(err)")
                }
                if let u = obj["usage"] as? [String: Any] { lastUsage = OpenAIWire.usage(u) }
                guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { continue }
                if let u = first["usage"] as? [String: Any] { lastUsage = OpenAIWire.usage(u) }
                guard let delta = first["delta"] as? [String: Any] else { continue }

                for key in ["reasoning_content", "reasoning"] {
                    if let r = delta[key] as? String, !r.isEmpty { cont.yield(.reasoning(r)); break }
                }
                if let text = delta["content"] as? String, !text.isEmpty { cont.yield(.text(text)) }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    for c in calls {
                        let idx = (c["index"] as? Int) ?? partials.count
                        let p = partials[idx] ?? PartialCall()
                        partials[idx] = p
                        if let id = c["id"] as? String, !id.isEmpty { p.id = id }
                        if let fn = c["function"] as? [String: Any] {
                            if let n = fn["name"] as? String { p.name += n }
                            if let a = fn["arguments"] as? String { p.args += a }
                        }
                    }
                }
            }

            for idx in partials.keys.sorted() {
                let p = partials[idx]!
                let id = p.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : p.id
                cont.yield(.toolCall(ToolCall(id: id, name: p.name, arguments: p.args.isEmpty ? "{}" : p.args)))
            }
            if let u = lastUsage { cont.yield(.usage(u)) }
        }
    }
}

// MARK: - Responses API

enum ResponsesWire {
    static func body(system: String, messages: [ChatMessage], tools: [ToolSpec], ctx: RequestContext) -> [String: Any] {
        var input: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .user:
                let (text, imgs) = LLMUtil.userParts(m, ctx)
                var parts: [[String: Any]] = []
                if !text.isEmpty { parts.append(["type": "input_text", "text": text]) }
                for b64 in imgs { parts.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(b64)"]) }
                input.append(["role": "user", "content": parts])
            case .assistant:
                if !m.content.isEmpty {
                    let part: [String: Any] = ["type": "output_text", "text": m.content]
                    input.append(["role": "assistant", "content": [part]])
                }
                for tc in m.toolCalls {
                    input.append(["type": "function_call", "call_id": tc.id, "name": tc.name, "arguments": tc.arguments])
                }
            case .tool:
                input.append(["type": "function_call_output", "call_id": m.toolCallId ?? "", "output": m.content])
            case .system:
                break
            }
        }
        var b: [String: Any] = ["model": ctx.model, "instructions": system, "input": input, "stream": true, "store": false]
        if let mt = ctx.entry.maxOutputTokens { b["max_output_tokens"] = mt }
        if let t = ctx.entry.overrides.temperature { b["temperature"] = t }
        if let p = ctx.entry.overrides.topP { b["top_p"] = p }
        if let level = ctx.thinking, level != .off, let effort = level.effort, OpenAIWire.sendsReasoning(ctx) {
            b["reasoning"] = ["effort": effort, "summary": "auto"]
        }
        if !tools.isEmpty {
            b["tools"] = tools.map { t -> [String: Any] in
                ["type": "function", "name": t.name, "description": t.description, "parameters": t.parameters]
            }
        }
        LLMUtil.mergeExtraBody(&b, ctx)
        return b
    }
}

struct OpenAIResponsesClient: LLMClient {
    let ctx: RequestContext

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        LLMUtil.makeStream { cont in
            var s = ctx.base + "/responses"
            if ctx.instance.azureMode && !s.contains("api-version=") { s += "?api-version=preview" }
            guard let url = URL(string: s) else { throw LLMError(message: "Base URL 无效：\(ctx.base)") }
            var req = try LLMUtil.postJSON(url, ResponsesWire.body(system: system, messages: messages, tools: tools, ctx: ctx), ctx)
            OpenAIWire.auth(&req, ctx)

            let bytes = try await LLMUtil.openSSE(req)
            for try await payload in LLMUtil.dataLines(bytes) {
                guard let obj = LLMUtil.jsonObject(payload) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                switch type {
                case "response.output_text.delta":
                    if let d = obj["delta"] as? String, !d.isEmpty { cont.yield(.text(d)) }
                case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                    if let d = obj["delta"] as? String, !d.isEmpty { cont.yield(.reasoning(d)) }
                case "response.output_item.done":
                    if let item = obj["item"] as? [String: Any], (item["type"] as? String) == "function_call" {
                        let id = (item["call_id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))"
                        let args = (item["arguments"] as? String) ?? "{}"
                        cont.yield(.toolCall(ToolCall(id: id, name: (item["name"] as? String) ?? "",
                                                      arguments: args.isEmpty ? "{}" : args)))
                    }
                case "response.completed", "response.incomplete":
                    if let r = obj["response"] as? [String: Any], let u = r["usage"] as? [String: Any] {
                        cont.yield(.usage(OpenAIWire.usage(u)))
                    }
                case "response.failed", "error":
                    let r = obj["response"] as? [String: Any]
                    let err = (r?["error"] ?? obj["error"]) as? [String: Any]
                    throw LLMError(kind: .providerError, message: (err?["message"] as? String) ?? payload)
                default:
                    break
                }
            }
        }
    }
}
