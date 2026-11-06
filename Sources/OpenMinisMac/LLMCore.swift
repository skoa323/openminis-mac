import Foundation

// Shared LLM plumbing: events, errors, request context, SSE helpers.

struct ToolSpec {
    let name: String
    let description: String
    let parameters: [String: Any]
}

enum LLMEvent {
    case text(String)
    case reasoning(String)
    case reasoningSignature(String)
    case toolCall(ToolCall)
    case usage(TokenUsage)
}

/// Error classification mirrors upstream LLMError: drives retry vs. fallback in group routing.
struct LLMError: LocalizedError {
    enum Kind { case invalidAPIKey, rateLimited, providerError, transient, network, other }
    var kind: Kind = .other
    let message: String
    var errorDescription: String? { message }

    init(message: String) { self.message = message }
    init(kind: Kind, message: String) { self.kind = kind; self.message = message }

    /// Transient / network errors are retried on the same model first.
    var isTransient: Bool { kind == .transient || kind == .network }

    static func http(_ status: Int, body: String) -> LLMError {
        let kind: Kind
        switch status {
        case 401, 403: kind = .invalidAPIKey
        case 429: kind = .rateLimited
        case 500, 502, 503, 504, 529: kind = .transient
        case 400..<500: kind = .providerError
        default: kind = .other
        }
        return LLMError(kind: kind, message: "HTTP \(status)：\(body)")
    }

    static func wrap(_ error: Error) -> LLMError {
        if let e = error as? LLMError { return e }
        if error is URLError { return LLMError(kind: .network, message: error.localizedDescription) }
        return LLMError(message: error.localizedDescription)
    }
}

/// Everything a client needs for one request.
struct RequestContext {
    let instance: ProviderInstance
    let entry: ModelEntry
    let apiKey: String
    /// Already clamped via `ModelEntry.effectiveThinking`; nil = send nothing.
    let thinking: ThinkingLevel?

    var model: String { entry.modelID }
    var base: String { instance.effectiveBaseURL }
}

protocol LLMClient {
    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error>
}

func makeClient(_ ctx: RequestContext) -> LLMClient {
    switch ctx.instance.type.wire {
    case .chat: return OpenAIChatClient(ctx: ctx)
    case .responses: return OpenAIResponsesClient(ctx: ctx)
    case .anthropic: return AnthropicClient(ctx: ctx)
    case .gemini: return GeminiClient(ctx: ctx)
    }
}

// MARK: - Helpers

enum LLMUtil {
    static func jsonObject(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// Per-model custom headers (forbidden names skipped) and custom User-Agent.
    static func applyCommonHeaders(_ req: inout URLRequest, _ ctx: RequestContext) {
        let ua = ctx.instance.customUserAgent.trimmingCharacters(in: .whitespaces)
        req.setValue(ua.isEmpty ? "OpenMinisMac/1.0" : ua, forHTTPHeaderField: "User-Agent")
        for (k, v) in ctx.entry.overrides.customHeaders
        where !ModelOverrides.forbiddenHeaders.contains(k.lowercased()) && !k.isEmpty {
            req.setValue(v, forHTTPHeaderField: k)
        }
    }

    /// Extra body params: values parsed as JSON when possible (numbers, bools, objects), else strings.
    static func mergeExtraBody(_ b: inout [String: Any], _ ctx: RequestContext) {
        for (k, v) in ctx.entry.overrides.extraBody where !k.isEmpty {
            b[k] = jsonObject(v) ?? v
        }
    }

    /// User message content, with images dropped (and noted) for text-only models.
    static func userParts(_ m: ChatMessage, _ ctx: RequestContext) -> (text: String, images: [String]) {
        if m.images.isEmpty { return (m.content, []) }
        if !ctx.entry.supportsImages {
            let note = "[用户附加了 \(m.images.count) 张图片，但当前模型不支持图片输入，已省略]"
            return (m.content.isEmpty ? note : m.content + "\n\n" + note, [])
        }
        return (m.content, m.images.compactMap { Attachments.base64($0) })
    }

    static func makeStream(_ body: @escaping (AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws -> Void)
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

    static func openSSE(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let e as URLError where e.code != .cancelled {
            throw LLMError(kind: .network, message: e.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError(message: "无效的响应")
        }
        if !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 4000 { break }
            }
            throw LLMError.http(http.statusCode, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return bytes
    }

    /// Yields the JSON payload of each `data:` SSE line.
    static func dataLines(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        cont.yield(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    static func int(_ any: Any?) -> Int { (any as? Int) ?? (any as? NSNumber)?.intValue ?? 0 }

    static func postJSON(_ url: URL, _ body: [String: Any], _ ctx: RequestContext) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyCommonHeaders(&req, ctx)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
}
