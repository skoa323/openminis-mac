import Foundation
import AppKit
import UniformTypeIdentifiers

extension ChatFolder {
    var isPinned: Bool { pinnedAt != nil }
}

// Session management wired to AppStore state: pin, folders, duplicate/fork, export, titles.
extension AppStore {
    // MARK: - Folder persistence

    nonisolated static var foldersFile: URL { supportDir.appendingPathComponent("folders.json") }

    static func loadFolders() -> [ChatFolder] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: foldersFile),
              let f = try? dec.decode([ChatFolder].self, from: d) else { return [] }
        return f
    }

    func saveFolders() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(folders) { try? d.write(to: AppStore.foldersFile, options: .atomic) }
    }

    func folder(_ id: UUID?) -> ChatFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    // MARK: - Conversation attributes

    private func update(_ id: UUID, _ body: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        body(&conversations[i])
        saveConversations()
    }

    func togglePin(_ ids: Set<UUID>) {
        let pinAll = ids.contains { conversation($0)?.isPinned == false }
        for id in ids { update(id) { $0.pinnedAt = pinAll ? Date() : nil } }
    }

    func rename(_ id: UUID, title: String, icon: String?) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) {
            $0.title = t.isEmpty ? Conversation.defaultTitle : String(t.prefix(80))
            $0.icon = icon
        }
    }

    // MARK: - Folders

    func findFolder(named name: String, excluding: UUID? = nil) -> ChatFolder? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return folders.first { $0.id != excluding && $0.name.lowercased() == n }
    }

    @discardableResult
    func createFolder(name: String, icon: String? = nil, moving ids: Set<UUID> = []) -> UUID {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let existing = findFolder(named: n) {
            move(ids, to: existing.id)
            return existing.id
        }
        let f = ChatFolder(name: n.isEmpty ? "新分组" : n, icon: icon)
        folders.append(f)
        saveFolders()
        move(ids, to: f.id)
        return f.id
    }

    /// Returns the conflicting folder instead of renaming when the name is taken (caller offers merge).
    func renameFolder(_ id: UUID, name: String, icon: String?) -> ChatFolder? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let other = findFolder(named: n, excluding: id) { return other }
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return nil }
        folders[i].name = n
        folders[i].icon = icon
        folders[i].updatedAt = Date()
        saveFolders()
        return nil
    }

    /// Moves every member of `source` into `target` and removes `source`.
    func mergeFolder(_ source: UUID, into target: UUID) {
        for i in conversations.indices where conversations[i].folderID == source {
            conversations[i].folderID = target
        }
        folders.removeAll { $0.id == source }
        saveFolders(); saveConversations()
    }

    func toggleFolderPin(_ id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].pinnedAt = folders[i].isPinned ? nil : Date()
        saveFolders()
    }

    /// Removes the folder; its conversations stay, unfiled.
    func dissolveFolder(_ id: UUID) {
        for i in conversations.indices where conversations[i].folderID == id {
            conversations[i].folderID = nil
        }
        folders.removeAll { $0.id == id }
        saveFolders(); saveConversations()
    }

    func deleteFolderWithSessions(_ id: UUID) {
        deleteConversations(Set(conversations.filter { $0.folderID == id }.map(\.id)))
        dissolveFolder(id)
    }

    func move(_ ids: Set<UUID>, to folderID: UUID?) {
        guard !ids.isEmpty else { return }
        for i in conversations.indices where ids.contains(conversations[i].id) {
            conversations[i].folderID = folderID
        }
        if let fid = folderID, let fi = folders.firstIndex(where: { $0.id == fid }) {
            folders[fi].updatedAt = Date()
            saveFolders()
        }
        saveConversations()
    }

    func newConversation(inFolder fid: UUID) {
        var c = Conversation()
        c.folderID = fid
        conversations.insert(c, at: 0)
        selectedID = c.id
        saveConversations()
    }

    // MARK: - Delete

    struct DeleteInfo { let count: Int; let messages: Int; let images: Int }

    func deleteInfo(_ ids: Set<UUID>) -> DeleteInfo {
        let cs = conversations.filter { ids.contains($0.id) }
        return DeleteInfo(count: cs.count,
                          messages: cs.reduce(0) { $0 + $1.messages.filter { $0.role != .tool }.count },
                          images: cs.reduce(0) { $0 + $1.messages.reduce(0) { $0 + $1.images.count } })
    }

    func deleteConversations(_ ids: Set<UUID>) {
        for id in ids { stop(id) }
        conversations.removeAll { ids.contains($0.id) }
        if conversations.isEmpty { conversations = [Conversation()] }
        if let s = selectedID, ids.contains(s) || !conversations.contains(where: { $0.id == s }) {
            selectedID = conversations.first?.id
        }
        saveConversations()
    }

    // MARK: - Duplicate / fork

    private func insertCopy(of src: Conversation, messages: [ChatMessage], word: String) {
        var c = Conversation()
        c.title = SessionCopy.copyTitle(src.title, existing: conversations.map(\.title), word: word)
        c.messages = SessionCopy.cloneMessages(messages)
        c.groupID = src.groupID
        c.thinkingLevel = src.thinkingLevel
        c.folderID = src.folderID
        c.icon = src.icon
        conversations.insert(c, at: 0)
        selectedID = c.id
        saveConversations()
    }

    func duplicate(_ id: UUID) {
        guard let src = conversation(id) else { return }
        insertCopy(of: src, messages: src.messages, word: SessionCopy.copyWord)
    }

    /// New conversation containing everything up to and including `messageID`.
    func fork(_ id: UUID, at messageID: UUID) {
        guard let src = conversation(id) else { return }
        insertCopy(of: src, messages: SessionCopy.forkPrefix(src.messages, through: messageID), word: SessionCopy.forkWord)
    }

    // MARK: - Export

    func export(_ ids: Set<UUID>, format: ExportFormat) {
        let convs = conversations.filter { ids.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
        guard !convs.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SessionExport.fileName(convs, format: format)
        panel.canCreateDirectories = true
        if let t = UTType(filenameExtension: format.ext) { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SessionExport.render(convs, format: format).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }

    // MARK: - Titles

    func regenerateTitle(_ id: UUID) {
        guard !titlingIDs.contains(id), let c = conversation(id),
              c.messages.contains(where: { $0.role == .user }) else { return }
        guard let g = group(for: id),
              let eid = ModelRouter.candidates(group: g, sessionKey: id.uuidString, isAvailable: { self.isAvailable($0) }).first,
              let e = entry(eid), let inst = instance(e.instanceID) else { return }
        titlingIDs.insert(id)
        let prompt = TitleGen.prompt(c)
        let ctx = RequestContext(instance: inst, entry: e, apiKey: inst.apiKey,
                                 thinking: e.supportsReasoning ? e.effectiveThinking(.off) : nil)
        Task { [weak self] in
            var out = ""
            do {
                let stream = makeClient(ctx).stream(system: "你只输出对话标题。",
                                                    messages: [ChatMessage(role: .user, content: prompt)], tools: [])
                for try await ev in stream {
                    if case .text(let t) = ev { out += t }
                    if out.count > 200 { break }
                }
            } catch {}
            guard let self else { return }
            self.titlingIDs.remove(id)
            let t = TitleGen.clean(out)
            if !t.isEmpty { self.update(id) { $0.title = t } }
        }
    }

    /// After the first completed exchange, replace the "first line" title with a generated one.
    func autoTitleIfNeeded(_ id: UUID) {
        guard settings.autoTitle, let c = conversation(id),
              c.messages.filter({ $0.role == .user }).count == 1,
              c.messages.contains(where: { $0.role == .assistant && !$0.isError && !$0.content.isEmpty }) else { return }
        regenerateTitle(id)
    }
}
