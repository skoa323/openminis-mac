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

    var activeProfile: ProviderProfile? {
        settings.profiles.first { $0.id == settings.activeProfileID } ?? settings.profiles.first
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
    private func apiHistory(_ id: UUID) -> [ChatMessage] {
        guard let c = conversation(id) else { return [] }
        var out: [ChatMessage] = []
        let msgs = c.messages
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

    private func runAgent(_ id: UUID) async {
        guard let profile = activeProfile else {
            append(ChatMessage(role: .assistant, content: "还没有配置模型。请打开设置（⌘,）添加一个模型服务。", isError: true), to: id)
            return
        }
        let apiKey = Keychain.get(profile.id.uuidString) ?? ""
        if apiKey.isEmpty && profile.kind == .anthropic {
            append(ChatMessage(role: .assistant, content: "「\(profile.name)」还没有填写 API Key。请打开设置（⌘,）填写。", isError: true), to: id)
            return
        }
        if apiKey.isEmpty && !profile.baseURL.contains("localhost") && !profile.baseURL.contains("127.0.0.1") {
            append(ChatMessage(role: .assistant, content: "「\(profile.name)」还没有填写 API Key。请打开设置（⌘,）填写。", isError: true), to: id)
            return
        }

        let client = makeClient(profile: profile, apiKey: apiKey)
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let runner = ToolRunner(workspace: workspaceURL, memoryFile: AppStore.memoryFile) { [weak self] cmd in
            guard let self else { return false }
            return await self.requestApproval(cmd, conversation: id)
        }
        let specs = ToolRunner.specs

        for _ in 0..<max(1, settings.maxIterations) {
            if Task.isCancelled { return }
            let assistant = ChatMessage(role: .assistant, content: "")
            append(assistant, to: id)
            var calls: [ToolCall] = []

            do {
                let stream = client.stream(system: systemPrompt(), messages: apiHistory(id), tools: specs)
                for try await ev in stream {
                    switch ev {
                    case .text(let t):
                        mutate(id, assistant.id) { $0.content += t }
                    case .reasoning(let r):
                        mutate(id, assistant.id) { $0.reasoning += r }
                    case .toolCall(let tc):
                        calls.append(tc)
                        mutate(id, assistant.id) { $0.toolCalls.append(tc) }
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                if (error as? URLError)?.code == .cancelled { return }
                append(ChatMessage(role: .assistant, content: "请求出错：\(error.localizedDescription)", isError: true), to: id)
                return
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
