import Foundation

// Port of upstream *ModelsAPI.swift + ModelsDevAPI.swift: fetch a provider's model list
// and fill missing facts (context window, reasoning, modalities, cost) from models.dev.

struct RemoteModel: Hashable {
    var id: String
    var info: ModelInfo
}

enum ModelCatalog {
    static func fetch(_ inst: ProviderInstance) async throws -> [RemoteModel] {
        let key = inst.apiKey
        let base = inst.effectiveBaseURL
        var req: URLRequest
        switch inst.type {
        case .anthropic:
            var b = base
            if !b.hasSuffix("/v1") { b += "/v1" }
            guard let u = URL(string: b + "/models?limit=512") else { throw LLMError(message: "Base URL 无效") }
            req = URLRequest(url: u)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            guard let u = URL(string: base + "/models?pageSize=1000") else { throw LLMError(message: "Base URL 无效") }
            req = URLRequest(url: u)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            guard let u = URL(string: base + "/models") else { throw LLMError(message: "Base URL 无效") }
            req = URLRequest(url: u)
            if inst.azureMode {
                req.setValue(key, forHTTPHeaderField: "api-key")
            } else if !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, body: String(data: data.prefix(2000), encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parse(obj, type: inst.type).sorted { $0.id < $1.id }
    }

    /// Pure parser, unit-tested.
    static func parse(_ obj: [String: Any], type: ProviderType) -> [RemoteModel] {
        if type == .gemini {
            let list = obj["models"] as? [[String: Any]] ?? []
            return list.compactMap { m in
                guard var id = m["name"] as? String else { return nil }
                if id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
                let methods = m["supportedGenerationMethods"] as? [String] ?? []
                if !methods.isEmpty && !methods.contains("generateContent") { return nil }
                var info = ModelInfo()
                info.name = m["displayName"] as? String
                info.contextWindow = m["inputTokenLimit"] as? Int
                info.maxOutput = m["outputTokenLimit"] as? Int
                if let t = m["thinking"] as? Bool { info.reasoning = t }
                return RemoteModel(id: id, info: info)
            }
        }
        let list = obj["data"] as? [[String: Any]] ?? obj["models"] as? [[String: Any]] ?? []
        return list.compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            var info = ModelInfo()
            info.name = (m["display_name"] as? String) ?? (m["name"] as? String)
            info.contextWindow = (m["context_length"] as? Int) ?? (m["context_window"] as? Int)
            if let arch = m["architecture"] as? [String: Any],
               let inputs = arch["input_modalities"] as? [String] {
                info.imageInput = inputs.contains("image")
            }
            if let params = m["supported_parameters"] as? [String] {
                info.reasoning = params.contains("reasoning") || params.contains("include_reasoning")
            }
            if let p = m["pricing"] as? [String: Any] {
                if let s = p["prompt"] as? String, let v = Double(s) { info.costInput = v * 1_000_000 }
                if let s = p["completion"] as? String, let v = Double(s) { info.costOutput = v * 1_000_000 }
            }
            return RemoteModel(id: id, info: info)
        }
    }

    // MARK: - models.dev

    static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    static var cacheFile: URL { AppStore.supportDir.appendingPathComponent("models.dev.json") }
    static let cacheTTL: TimeInterval = 48 * 3600

    static func modelsDev() async -> [String: Any]? {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: cacheFile.path),
           let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) < cacheTTL,
           let d = try? Data(contentsOf: cacheFile),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        do {
            var req = URLRequest(url: modelsDevURL)
            req.timeoutInterval = 30
            let (d, _) = try await URLSession.shared.data(for: req)
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            try? d.write(to: cacheFile, options: .atomic)
            return o
        } catch {
            // Stale cache is better than nothing.
            if let d = try? Data(contentsOf: cacheFile) {
                return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            }
            return nil
        }
    }

    /// Looks a model up in models.dev: provider whose `api` matches the base host first, then any provider.
    static func lookup(_ db: [String: Any], modelID: String, baseURL: String) -> ModelInfo? {
        let host = URL(string: baseURL)?.host ?? ""
        let bare = modelID.split(separator: "/").last.map(String.init) ?? modelID
        var preferred: [[String: Any]] = []
        var others: [[String: Any]] = []
        for (_, v) in db {
            guard let p = v as? [String: Any] else { continue }
            let api = (p["api"] as? String) ?? ""
            if !host.isEmpty, let ah = URL(string: api)?.host, ah == host { preferred.append(p) } else { others.append(p) }
        }
        for p in preferred + others {
            guard let models = p["models"] as? [String: Any] else { continue }
            if let m = (models[modelID] ?? models[bare]) as? [String: Any] { return info(from: m) }
        }
        return nil
    }

    static func info(from m: [String: Any]) -> ModelInfo {
        var i = ModelInfo()
        i.name = m["name"] as? String
        if let l = m["limit"] as? [String: Any] {
            i.contextWindow = l["context"] as? Int
            i.maxOutput = l["output"] as? Int
        }
        i.reasoning = m["reasoning"] as? Bool
        if let mods = m["modalities"] as? [String: Any], let input = mods["input"] as? [String] {
            i.imageInput = input.contains("image")
        }
        if let opts = m["reasoning_options"] as? [[String: Any]] {
            let vals = opts.filter { ($0["type"] as? String) == "effort" }.flatMap { ($0["values"] as? [String]) ?? [] }
            if !vals.isEmpty { i.efforts = vals }
        }
        if let c = m["cost"] as? [String: Any] {
            i.costInput = (c["input"] as? NSNumber)?.doubleValue
            i.costOutput = (c["output"] as? NSNumber)?.doubleValue
        }
        return i
    }

    /// Fills only fields the provider list left empty.
    static func merge(_ a: ModelInfo, _ b: ModelInfo?) -> ModelInfo {
        guard let b else { return a }
        var r = a
        r.name = r.name ?? b.name
        r.contextWindow = r.contextWindow ?? b.contextWindow
        r.maxOutput = r.maxOutput ?? b.maxOutput
        r.reasoning = r.reasoning ?? b.reasoning
        r.imageInput = r.imageInput ?? b.imageInput
        r.efforts = r.efforts ?? b.efforts
        r.costInput = r.costInput ?? b.costInput
        r.costOutput = r.costOutput ?? b.costOutput
        return r
    }
}
