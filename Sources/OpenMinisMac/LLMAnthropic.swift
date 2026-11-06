import Foundation

// Anthropic Messages API. Port of upstream Anthropic/AnthropicAgentProvider + ThinkingRuleResolver (Claude rules).

enum AnthropicWire {
    /// Claude 4.6+ uses adaptive thinking + output_config.effort; older models use budget_tokens.
    static func isAdaptive(_ model: String) -> Bool {
        let m = model.lowercased()
        for family in ["opus", "sonnet", "haiku"] {
            guard let r = m.range(of: "claude-\(family)-") else { continue }
            let nums = m[r.upperBound...].split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
            guard let major = nums.first else { return false }
            // Date suffixes like 20250514 are not minor versions.
            let minor = nums.count > 1 && nums[1] < 100 ? nums[1] : 0
            return major >= 5 || (major == 4 && minor >= 6)
        }
        return false
    }

    static func budget(_ level: ThinkingLevel, maxTokens: Int) -> Int {
        let raw: Int
        switch level {
        case .off: raw = 0
        case .low: raw = 8192
        case .medium: raw = 32768
        case .high: raw = min(maxTokens, 65536)
        case .xhigh, .max, .ultra: raw = maxTokens
        }
        return max(1024, min(raw, maxTokens - 1))
    }

    static func messagesURL(_ ctx: RequestContext) -> URL? {
        var b = ctx.base
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b.hasSuffix("/v1") ? b + "/messages" : b + "/v1/messages")
    }

    static func body(system: String, messages: [ChatMessage], tools: [ToolSpec], ctx: RequestContext) -> [String: Any] {
        let thinkingOn = (ctx.thinking ?? .off) != .off
        let maxTokens = ctx.entry.maxOutputTokens ?? (thinkingOn ? 64000 : 8192)
        var msgs: [[String: Any]] = []

        func append(role: String, blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = msgs.last, (last["role"] as? String) == role,
               var existing = last["content"] as? [[String: Any]] {
                existing.append(contentsOf: blocks)
                msgs[msgs.count - 1]["content"] = existing
            } else {
                msgs.append(["role": role, "content": blocks])
            }
        }

        for m in messages {
            switch m.role {
            case .user:
                let (text, imgs) = LLMUtil.userParts(m, ctx)
                var blocks: [[String: Any]] = []
                for b64 in imgs {
                    let src: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": b64]
                    blocks.append(["type": "image", "source": src])
                }
                if !text.isEmpty || blocks.isEmpty { blocks.append(["type": "text", "text": text.isEmpty ? " " : text]) }
                append(role: "user", blocks: blocks)
            case .assistant:
                var blocks: [[String: Any]] = []
                // Signed thinking must be replayed before tool_use when thinking is enabled.
                if thinkingOn, !m.toolCalls.isEmpty, let sig = m.reasoningSignature, !sig.isEmpty {
                    blocks.append(["type": "thinking", "thinking": m.reasoning, "signature": sig])
                }
                if !m.content.isEmpty { blocks.append(["type": "text", "text": m.content]) }
                for tc in m.toolCalls {
                    let input = (LLMUtil.jsonObject(tc.arguments) as? [String: Any]) ?? [:]
                    blocks.append(["type": "tool_use", "id": tc.id, "name": tc.name, "input": input])
                }
                append(role: "assistant", blocks: blocks)
            case .tool:
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": m.toolCallId ?? "", "content": m.content]
                if m.isError { block["is_error"] = true }
                append(role: "user", blocks: [block])
            case .system:
                break
            }
        }

        var b: [String: Any] = [
            "model": ctx.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": msgs,
            "stream": true,
        ]
        if let level = ctx.thinking, level != .off {
            if isAdaptive(ctx.model) {
                b["thinking"] = ["type": "adaptive", "display": "summarized"]
                let effort: String
                switch level {
                case .low: effort = "low"
                case .medium: effort = "medium"
                case .high: effort = "high"
                default: effort = "max"
                }
                b["output_config"] = ["effort": effort]
            } else {
                b["thinking"] = ["type": "enabled", "budget_tokens": budget(level, maxTokens: maxTokens)]
            }
        } else {
            // Anthropic requires default temperature while thinking is on.
            if let t = ctx.entry.overrides.temperature { b["temperature"] = t }
            if let p = ctx.entry.overrides.topP { b["top_p"] = p }
        }
        if !tools.isEmpty {
            b["tools"] = tools.map { t -> [String: Any] in
                ["name": t.name, "description": t.description, "input_schema": t.parameters]
            }
        }
        LLMUtil.mergeExtraBody(&b, ctx)
        return b
    }
}

struct AnthropicClient: LLMClient {
    let ctx: RequestContext

    private final class Block { var type = ""; var id = ""; var name = ""; var json = "" }

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        LLMUtil.makeStream { cont in
            guard let url = AnthropicWire.messagesURL(ctx) else { throw LLMError(message: "Base URL 无效：\(ctx.base)") }
            var req = try LLMUtil.postJSON(url, AnthropicWire.body(system: system, messages: messages, tools: tools, ctx: ctx), ctx)
            req.setValue(ctx.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let bytes = try await LLMUtil.openSSE(req)
            var blocks: [Int: Block] = [:]
            var usage = TokenUsage()
            var sawUsage = false

            for try await payload in LLMUtil.dataLines(bytes) {
                guard let obj = LLMUtil.jsonObject(payload) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                let index = (obj["index"] as? Int) ?? 0

                switch type {
                case "message_start":
                    if let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                        usage.input = LLMUtil.int(u["input_tokens"])
                        usage.cacheRead = LLMUtil.int(u["cache_read_input_tokens"])
                        usage.cacheWrite = LLMUtil.int(u["cache_creation_input_tokens"])
                        usage.output = LLMUtil.int(u["output_tokens"])
                        sawUsage = true
                    }
                case "message_delta":
                    if let u = obj["usage"] as? [String: Any] {
                        usage.output = LLMUtil.int(u["output_tokens"])
                        sawUsage = true
                    }
                case "content_block_start":
                    let b = Block()
                    if let cb = obj["content_block"] as? [String: Any] {
                        b.type = (cb["type"] as? String) ?? ""
                        b.id = (cb["id"] as? String) ?? ""
                        b.name = (cb["name"] as? String) ?? ""
                    }
                    blocks[index] = b
                case "content_block_delta":
                    guard let delta = obj["delta"] as? [String: Any] else { continue }
                    if let text = delta["text"] as? String, !text.isEmpty { cont.yield(.text(text)) }
                    if let th = delta["thinking"] as? String, !th.isEmpty { cont.yield(.reasoning(th)) }
                    if let sig = delta["signature"] as? String, !sig.isEmpty { cont.yield(.reasoningSignature(sig)) }
                    if let pj = delta["partial_json"] as? String { blocks[index]?.json += pj }
                case "content_block_stop":
                    if let b = blocks[index], b.type == "tool_use" {
                        cont.yield(.toolCall(ToolCall(id: b.id, name: b.name, arguments: b.json.isEmpty ? "{}" : b.json)))
                    }
                case "error":
                    let err = obj["error"] as? [String: Any]
                    let et = (err?["type"] as? String) ?? ""
                    let kind: LLMError.Kind = et == "overloaded_error" || et == "api_error" ? .transient
                        : et == "rate_limit_error" ? .rateLimited : .providerError
                    throw LLMError(kind: kind, message: (err?["message"] as? String) ?? payload)
                default:
                    break
                }
            }
            if sawUsage { cont.yield(.usage(usage)) }
        }
    }
}
