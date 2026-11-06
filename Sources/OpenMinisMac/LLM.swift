import Foundation

struct ToolSpec {
    let name: String
    let description: String
    let parameters: [String: Any]
}

enum LLMEvent {
    case text(String)
    case toolCall(ToolCall)
}

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol LLMClient {
    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error>
}

func makeClient(profile: ProviderProfile, apiKey: String) -> LLMClient {
    switch profile.kind {
    case .openai: return OpenAIClient(profile: profile, apiKey: apiKey)
    case .anthropic: return AnthropicClient(profile: profile, apiKey: apiKey)
    }
}

// MARK: - Shared helpers

private func trimmedBase(_ s: String) -> String {
    var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while b.hasSuffix("/") { b.removeLast() }
    return b
}

private func jsonObject(_ s: String) -> Any? {
    guard let d = s.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d)
}

/// Runs `body` in a child task and bridges it into an AsyncThrowingStream.
/// Cancelling the consumer cancels the network request.
private func makeStream(_ body: @escaping (AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws -> Void)
    -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func openSSE(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw LLMError(message: "无效的响应")
    }
    if !(200..<300).contains(http.statusCode) {
        var body = ""
        for try await line in bytes.lines {
            body += line + "\n"
            if body.count > 4000 { break }
        }
        throw LLMError(message: "HTTP \(http.statusCode)：\(body.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return bytes
}

// MARK: - OpenAI-compatible (OpenAI, DeepSeek, Gemini, OpenRouter, Ollama…)

struct OpenAIClient: LLMClient {
    let profile: ProviderProfile
    let apiKey: String

    private final class PartialCall {
        var id = ""
        var name = ""
        var args = ""
    }

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        makeStream { cont in
            guard let url = URL(string: trimmedBase(profile.baseURL) + "/chat/completions") else {
                throw LLMError(message: "Base URL 无效")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body(system: system, messages: messages, tools: tools))

            let bytes = try await openSSE(req)
            var partials: [Int: PartialCall] = [:]

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let obj = jsonObject(payload) as? [String: Any] else { continue }
                if let err = obj["error"] as? [String: Any] {
                    throw LLMError(message: (err["message"] as? String) ?? "\(err)")
                }
                guard let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { continue }

                if let text = delta["content"] as? String, !text.isEmpty {
                    cont.yield(.text(text))
                }
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
        }
    }

    private func body(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> [String: Any] {
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user:
                msgs.append(["role": "user", "content": m.content])
            case .assistant:
                var d: [String: Any] = ["role": "assistant"]
                d["content"] = m.content.isEmpty ? NSNull() : m.content
                if !m.toolCalls.isEmpty {
                    d["tool_calls"] = m.toolCalls.map { tc -> [String: Any] in
                        let fn: [String: Any] = ["name": tc.name, "arguments": tc.arguments]
                        return ["id": tc.id, "type": "function", "function": fn]
                    }
                }
                msgs.append(d)
            case .tool:
                msgs.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.content])
            case .system:
                break
            }
        }
        var b: [String: Any] = ["model": profile.model, "messages": msgs, "stream": true]
        if !tools.isEmpty {
            b["tools"] = tools.map { t -> [String: Any] in
                let fn: [String: Any] = ["name": t.name, "description": t.description, "parameters": t.parameters]
                return ["type": "function", "function": fn]
            }
        }
        return b
    }
}

// MARK: - Anthropic Messages API

struct AnthropicClient: LLMClient {
    let profile: ProviderProfile
    let apiKey: String

    private final class Block {
        var type = ""
        var id = ""
        var name = ""
        var json = ""
    }

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        makeStream { cont in
            guard let url = URL(string: trimmedBase(profile.baseURL) + "/v1/messages") else {
                throw LLMError(message: "Base URL 无效")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = try JSONSerialization.data(withJSONObject: body(system: system, messages: messages, tools: tools))

            let bytes = try await openSSE(req)
            var blocks: [Int: Block] = [:]

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let obj = jsonObject(payload) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                let index = (obj["index"] as? Int) ?? 0

                switch type {
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
                    if let text = delta["text"] as? String, !text.isEmpty {
                        cont.yield(.text(text))
                    }
                    if let pj = delta["partial_json"] as? String {
                        blocks[index]?.json += pj
                    }
                case "content_block_stop":
                    if let b = blocks[index], b.type == "tool_use" {
                        cont.yield(.toolCall(ToolCall(id: b.id, name: b.name, arguments: b.json.isEmpty ? "{}" : b.json)))
                    }
                case "error":
                    let err = obj["error"] as? [String: Any]
                    throw LLMError(message: (err?["message"] as? String) ?? payload)
                default:
                    break
                }
            }
        }
    }

    private func body(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> [String: Any] {
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
                append(role: "user", blocks: [["type": "text", "text": m.content]])
            case .assistant:
                var blocks: [[String: Any]] = []
                if !m.content.isEmpty { blocks.append(["type": "text", "text": m.content]) }
                for tc in m.toolCalls {
                    let input = (jsonObject(tc.arguments) as? [String: Any]) ?? [:]
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
            "model": profile.model,
            "max_tokens": 8192,
            "system": system,
            "messages": msgs,
            "stream": true,
        ]
        if !tools.isEmpty {
            b["tools"] = tools.map { t -> [String: Any] in
                ["name": t.name, "description": t.description, "input_schema": t.parameters]
            }
        }
        return b
    }
}
