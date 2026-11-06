import Foundation
import SwiftUI

struct PendingApproval: Identifiable {
    let id = UUID()
    let conversationID: UUID
    let command: String
    let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
final class AppStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedID: UUID?
    @Published var settings: AppSettings { didSet { saveSettings() } }
    @Published private(set) var runningIDs: Set<UUID> = []
    @Published private(set) var approvals: [PendingApproval] = []

    private var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    init() {
        let s = AppStore.loadSettings()
        self.settings = s
        self.conversations = AppStore.loadConversations()
        if conversations.isEmpty { conversations = [Conversation()] }
        selectedID = conversations.first?.id
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    // MARK: - Paths & persistence

    nonisolated static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OpenMinisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var conversationsFile: URL { supportDir.appendingPathComponent("conversations.json") }
    nonisolated static var settingsFile: URL { supportDir.appendingPathComponent("settings.json") }
    nonisolated static var memoryFile: URL { supportDir.appendingPathComponent("MEMORY.md") }

    var workspaceURL: URL {
        URL(fileURLWithPath: (settings.workspacePath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func loadSettings() -> AppSettings {
        guard let d = try? Data(contentsOf: settingsFile),
              let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return .initial }
        return s
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) {
            try? d.write(to: AppStore.settingsFile, options: .atomic)
        }
    }

    private static func loadConversations() -> [Conversation] {
        guard let d = try? Data(contentsOf: conversationsFile) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let c = try? dec.decode([Conversation].self, from: d) { return c }
        // Keep a copy of unreadable data instead of silently overwriting it.
        let backup = supportDir.appendingPathComponent("conversations.broken-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: conversationsFile, to: backup)
        return []
    }

    func saveConversations() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(conversations) {
            try? d.write(to: AppStore.conversationsFile, options: .atomic)
        }
    }

    // MARK: - Conversations

    // MARK: - Providers / groups

    func instance(_ id: UUID) -> ProviderInstance? { settings.instances.first { $0.id == id } }
    func entry(_ id: String) -> ModelEntry? { settings.entries.first { $0.id == id } }

    /// Member usable right now: entry visible, instance enabled and has a credential.
    func isAvailable(_ entryID: String) -> Bool {
        guard let e = entry(entryID), !e.isHidden, let inst = instance(e.instanceID) else { return false }
        return inst.isEnabled && inst.hasCredential
    }

    func group(for conversationID: UUID?) -> ModelGroup? {
        let cg = conversationID.flatMap { conversation($0)?.groupID }
        for gid in [cg, settings.activeGroupID].compactMap({ $0 }) {
            if let g = settings.groups.first(where: { $0.id == gid }) { return g }
        }
        return settings.groups.first
    }

    func thinking(for conversationID: UUID?) -> ThinkingLevel {
        if let id = conversationID, let t = conversation(id)?.thinkingLevel { return t }
        return group(for: conversationID)?.defaultThinkingLevel ?? settings.defaultThinkingLevel
    }

    func setGroup(_ gid: UUID?, for conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].groupID = gid
        if let gid { settings.activeGroupID = gid }
    }

    func setThinking(_ t: ThinkingLevel, for conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].thinkingLevel = t
        settings.defaultThinkingLevel = t
    }

    func entryLabel(_ e: ModelEntry) -> String {
        "\(instance(e.instanceID)?.label ?? "?") · \(e.displayName)"
    }

    // MARK: - Usage log

    struct UsageRecord: Codable, Hashable {
        var date: Date
        var entryID: String
        var label: String
        var usage: TokenUsage
    }
    @Published private(set) var usageLog: [UsageRecord] = AppStore.loadUsage()
    nonisolated static var usageFile: URL { supportDir.appendingPathComponent("usage.json") }

    private static func loadUsage() -> [UsageRecord] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: usageFile),
              let u = try? dec.decode([UsageRecord].self, from: d) else { return [] }
        return u
    }
    private func saveUsage() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(usageLog) { try? d.write(to: AppStore.usageFile, options: .atomic) }
    }
    private func recordUsage(_ u: TokenUsage, entry e: ModelEntry) {
        usageLog.append(UsageRecord(date: Date(), entryID: e.id, label: entryLabel(e), usage: u))
        if usageLog.count > 20000 { usageLog.removeFirst(usageLog.count - 20000) }
        saveUsage()
    }
    func clearUsage() { usageLog = []; saveUsage() }

    // MARK: - Model lists

    @Published var fetchingInstances: Set<UUID> = []
    @Published var fetchErrors: [UUID: String] = [:]

    /// Pulls /models for an instance, enriches from models.dev, merges into entries.
    func refreshModels(_ instanceID: UUID) async {
        guard let inst = instance(instanceID) else { return }
        fetchingInstances.insert(instanceID)
        fetchErrors[instanceID] = nil
        defer { fetchingInstances.remove(instanceID) }
        do {
            let remote = try await ModelCatalog.fetch(inst)
            let db = await ModelCatalog.modelsDev()
            let base = inst.effectiveBaseURL
            var entries = settings.entries
            for rm in remote {
                let mid = rm.id
                let info = db.map { ModelCatalog.merge(rm.info, ModelCatalog.lookup($0, modelID: mid, baseURL: base)) } ?? rm.info
                if let i = entries.firstIndex(where: { $0.instanceID == instanceID && $0.modelID == mid }) {
                    entries[i].info = info
                } else {
                    var e = ModelEntry(instanceID: instanceID, modelID: mid, info: info)
                    e.isHidden = true   // newly discovered models start hidden; user picks which to show
                    entries.append(e)
                }
            }
            settings.entries = entries
        } catch {
            fetchErrors[instanceID] = error.localizedDescription
        }
    }

    func removeInstance(_ id: UUID) {
        let removed = Set(settings.entries.filter { $0.instanceID == id }.map(\.id))
        settings.entries.removeAll { $0.instanceID == id }
        for i in settings.groups.indices { settings.groups[i].members.removeAll { removed.contains($0) } }
        settings.instances.removeAll { $0.id == id }
        Keychain.delete(id.uuidString)
    }

    func removeEntry(_ entryID: String) {
        settings.entries.removeAll { $0.id == entryID }
        for i in settings.groups.indices { settings.groups[i].members.removeAll { $0 == entryID } }
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func newConversation() {
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selectedID = empty.id
            return
        }
        let c = Conversation()
        conversations.insert(c, at: 0)
        selectedID = c.id
    }

    func delete(_ id: UUID) {
        stop(id)
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [Conversation()] }
        if selectedID == id || !conversations.contains(where: { $0.id == selectedID }) {
            selectedID = conversations.first?.id
        }
        saveConversations()
    }

    func clear(_ id: UUID) {
        stop(id)
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages = []
        conversations[i].title = Conversation.defaultTitle
        saveConversations()
    }

    private func touch(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].updatedAt = Date()
        if i != 0 {
            let c = conversations.remove(at: i)
            conversations.insert(c, at: 0)
        }
    }

    private func append(_ m: ChatMessage, to id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.append(m)
    }

    private func mutate(_ cid: UUID, _ mid: UUID, _ body: (inout ChatMessage) -> Void) {
        guard let ci = conversations.firstIndex(where: { $0.id == cid }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == mid }) else { return }
        body(&conversations[ci].messages[mi])
    }

    // MARK: - Running

    func isRunning(_ id: UUID) -> Bool { runningIDs.contains(id) }

    func send(_ text: String, images: [String] = [], in id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, !isRunning(id),
              let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if conversations[i].messages.isEmpty || conversations[i].title == Conversation.defaultTitle {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            conversations[i].title = firstLine.isEmpty ? "图片" : String(firstLine.prefix(30))
        }
        conversations[i].messages.append(ChatMessage(role: .user, content: trimmed, images: images))
        touch(id)
        saveConversations()
        start(id)
    }

    /// Drops everything after the user turn that produced `messageID` and runs again.
    func regenerate(_ messageID: UUID, in id: UUID) {
        guard !isRunning(id), let ci = conversations.firstIndex(where: { $0.id == id }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let msgs = conversations[ci].messages
        guard let ui = msgs[...mi].lastIndex(where: { $0.role == .user }) else { return }
        conversations[ci].messages.removeSubrange((ui + 1)...)
        saveConversations()
        start(id)
    }

    /// Replaces a user message's text, discards the replies after it, and runs again.
    func edit(_ messageID: UUID, newText: String, in id: UUID) {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning(id), let ci = conversations.firstIndex(where: { $0.id == id }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }),
              conversations[ci].messages[mi].role == .user,
              !t.isEmpty || !conversations[ci].messages[mi].images.isEmpty else { return }
        conversations[ci].messages[mi].content = t
        conversations[ci].messages.removeSubrange((mi + 1)...)
        saveConversations()
        start(id)
    }

    private func start(_ id: UUID) {
        let token = UUID()
        runningIDs.insert(id)
        let task = Task { [weak self] in
            await self?.runAgent(id)
            self?.finish(id, token: token)
        }
        tasks[id] = (token, task)
    }

    private func finish(_ id: UUID, token: UUID) {
        guard tasks[id]?.token == token else { return }
        tasks[id] = nil
        runningIDs.remove(id)
        saveConversations()
    }

    func stop(_ id: UUID) {
        tasks[id]?.task.cancel()
        tasks[id] = nil
        runningIDs.remove(id)
        let mine = approvals.filter { $0.conversationID == id }
        approvals.removeAll { $0.conversationID == id }
        for a in mine { a.continuation.resume(returning: false) }
        saveConversations()
    }

    // MARK: - Approvals

    private func requestApproval(_ command: String, conversation id: UUID) async -> Bool {
        if !settings.confirmShell { return true }
        if Task.isCancelled { return false }
        return await withCheckedContinuation { cont in
            approvals.append(PendingApproval(conversationID: id, command: command, continuation: cont))
        }
    }

    func resolve(_ approvalID: UUID, allow: Bool, always: Bool = false) {
        guard let i = approvals.firstIndex(where: { $0.id == approvalID }) else { return }
        let a = approvals.remove(at: i)
        if always { settings.confirmShell = false }
        a.continuation.resume(returning: allow)
    }

    func approval(for conversation: UUID) -> PendingApproval? {
        approvals.first { $0.conversationID == conversation }
    }

    // MARK: - Agent loop

    private func systemPrompt() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let osv = ProcessInfo.processInfo.operatingSystemVersionString
        var p = """
        你是 OpenMinis，一个运行在用户 Mac 上的 AI 助手（原生 macOS 版）。
        你可以通过工具直接操作这台电脑：shell（/bin/zsh，真实的 macOS 环境，可用 brew、git、python3、osascript 等）、读写和编辑文件、获取网页、写入长期记忆。

        环境：
        - 系统：macOS \(osv)
        - 用户主目录：\(NSHomeDirectory())
        - 工作区（shell 的默认目录，相对路径以此为基准）：\(workspaceURL.path)
        - 当前时间：\(f.string(from: Date()))

        原则：
        - 能用工具完成的事就直接做，不要只给建议。
        - 删除文件、覆盖重要数据、修改系统设置等不可逆操作，先向用户说明并确认。
        - 回答简洁，使用用户的语言。
        - 发现用户偏好或重要约定时，用 memory_write 记下来。
        """
        if let mem = try? String(contentsOf: AppStore.memoryFile, encoding: .utf8),
           !mem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p += "\n\n以下是你之前记下的长期记忆：\n" + String(mem.suffix(8000))
        }
        let custom = settings.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { p += "\n\n用户的附加指示：\n" + custom }
        return p
    }

    /// History as sent to the model: drops local error notices and empty assistant turns,
    /// and patches any tool call that never got a result (e.g. after a stop).
    private func apiHistory(_ id: UUID, limit: Int? = nil) -> [ChatMessage] {
        guard let c = conversation(id) else { return [] }
        var out: [ChatMessage] = []
        var msgs = c.messages
        // Context limit: drop the oldest turns, always restarting at a user message.
        if let limit, limit > 0 {
            var total = msgs.reduce(0) { $0 + AppStore.estimateTokens($1) }
            while total > limit, let next = msgs.dropFirst().firstIndex(where: { $0.role == .user }) {
                total -= msgs[..<next].reduce(0) { $0 + AppStore.estimateTokens($1) }
                msgs.removeSubrange(..<next)
            }
        }
        var i = 0
        while i < msgs.count {
            let m = msgs[i]
            if m.role == .assistant && (m.isError || (m.content.isEmpty && m.toolCalls.isEmpty)) {
                i += 1; continue
            }
            out.append(m)
            if m.role == .assistant && !m.toolCalls.isEmpty {
                var j = i + 1
                var results: [ChatMessage] = []
                while j < msgs.count && msgs[j].role == .tool { results.append(msgs[j]); j += 1 }
                let answered = Set(results.compactMap { $0.toolCallId })
                for tc in m.toolCalls where !answered.contains(tc.id) {
                    out.append(ChatMessage(role: .tool, content: "（已取消）", toolCallId: tc.id, toolName: tc.name, isError: true))
                }
                out.append(contentsOf: results)
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    /// Rough token estimate (chars / 3, images ~1k) used for the group's context limit.
    private static func estimateTokens(_ m: ChatMessage) -> Int {
        let chars = m.content.count + m.reasoning.count + m.toolCalls.reduce(0) { $0 + $1.arguments.count }
        return chars / 3 + m.images.count * 1000 + 4
    }

    private func runAgent(_ id: UUID) async {
        guard let g = group(for: id) else {
            append(ChatMessage(role: .assistant, content: "还没有模型分组。请打开设置（⌘,）→ 模型分组，新建一个分组并加入模型。", isError: true), to: id)
            return
        }
        let cands = ModelRouter.candidates(group: g, sessionKey: id.uuidString, isAvailable: { [unowned self] in self.isAvailable($0) })
        if cands.isEmpty {
            append(ChatMessage(role: .assistant, content: "分组「\(g.name)」里没有可用模型。请打开设置（⌘,），给服务商填写 API Key，并把模型加入该分组。", isError: true), to: id)
            return
        }
        let requested = thinking(for: id)

        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let runner = ToolRunner(workspace: workspaceURL, memoryFile: AppStore.memoryFile) { [weak self] cmd in
            guard let self else { return false }
            return await self.requestApproval(cmd, conversation: id)
        }
        let specs = ToolRunner.specs
        var ci = 0   // current candidate; sticks across tool iterations once a fallback happened

        for _ in 0..<max(1, settings.maxIterations) {
            if Task.isCancelled { return }
            let assistant = ChatMessage(role: .assistant, content: "")
            append(assistant, to: id)
            var calls: [ToolCall] = []
            var retryAttempt = 0

            attempt: while true {
                guard ci < cands.count, let e = entry(cands[ci]), let inst = instance(e.instanceID) else {
                    append(ChatMessage(role: .assistant, content: "分组「\(g.name)」里的模型都不可用。", isError: true), to: id)
                    return
                }
                let label = entryLabel(e)
                mutate(id, assistant.id) {
                    $0.content = ""; $0.reasoning = ""; $0.reasoningSignature = nil
                    $0.toolCalls = []; $0.usage = nil; $0.modelLabel = label
                }
                calls = []
                var lastUsage: TokenUsage? = nil
                let ctx = RequestContext(instance: inst, entry: e, apiKey: inst.apiKey,
                                         thinking: e.effectiveThinking(requested))
                do {
                    let stream = makeClient(ctx).stream(system: systemPrompt(),
                                                        messages: apiHistory(id, limit: g.contextLimitTokens),
                                                        tools: specs)
                    for try await ev in stream {
                        switch ev {
                        case .text(let t):
                            mutate(id, assistant.id) { $0.content += t }
                        case .reasoning(let r):
                            mutate(id, assistant.id) { $0.reasoning += r }
                        case .reasoningSignature(let s):
                            mutate(id, assistant.id) { $0.reasoningSignature = s }
                        case .toolCall(let tc):
                            calls.append(tc)
                            mutate(id, assistant.id) { $0.toolCalls.append(tc) }
                        case .usage(let u):
                            lastUsage = u
                            mutate(id, assistant.id) { $0.usage = u }
                        }
                    }
                    if let u = lastUsage { recordUsage(u, entry: e) }
                    break attempt
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    if (error as? URLError)?.code == .cancelled { return }
                    let le = LLMError.wrap(error)
                    // limited: transient/network errors walk the upstream retry ladder on the same model first
                    // (AIChatViewModel+Fallback.swift); `always` falls back immediately.
                    let hasNext = ci + 1 < cands.count
                    if g.fallbackPolicy == .limited && le.isTransient {
                        let delays = ModelRouter.retryDelays(for: le, hasFallbackTarget: hasNext)
                        if retryAttempt < delays.count {
                            let wait = delays[retryAttempt]
                            retryAttempt += 1
                            mutate(id, assistant.id) {
                                $0.modelLabel = "\(label) · 第 \(retryAttempt)/\(delays.count) 次重试（\(wait) 秒后）"
                            }
                            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                            if Task.isCancelled { return }
                            continue attempt
                        }
                    }
                    if hasNext {
                        ci += 1
                        retryAttempt = 0
                        continue attempt
                    }
                    mutate(id, assistant.id) { $0.toolCalls = [] }
                    append(ChatMessage(role: .assistant, content: "请求出错（\(label)）：\(le.message)", isError: true), to: id)
                    return
                }
            }

            if calls.isEmpty { return }

            for tc in calls {
                if Task.isCancelled { return }
                let r = await runner.run(tc)
                if Task.isCancelled { return }
                append(ChatMessage(role: .tool, content: r.output, toolCallId: tc.id, toolName: tc.name, isError: r.isError), to: id)
            }
            saveConversations()
        }
        append(ChatMessage(role: .assistant, content: "已达到单轮最大工具调用次数（\(settings.maxIterations)），已暂停。回复「继续」可接着执行。", isError: true), to: id)
    }
}
