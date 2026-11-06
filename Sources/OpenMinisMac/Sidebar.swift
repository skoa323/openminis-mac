import SwiftUI
import AppKit

// Port of upstream ContentView+SessionList / SessionRow / SessionContextMenu / folder sheets.

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: Set<UUID> = []
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("expandedFolderIDs") private var expandedRaw = ""
    @State private var renaming: Conversation?
    @State private var folderSheet: FolderSheet?
    @State private var pendingDelete: Set<UUID> = []
    @State private var confirmDelete = false

    private var expanded: Set<String> { Set(expandedRaw.split(separator: ",").map(String.init)) }
    private func setExpanded(_ f: UUID, _ on: Bool) {
        // Accordion like upstream: expanding one folder collapses the others.
        expandedRaw = on ? f.uuidString : expanded.subtracting([f.uuidString]).joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: $selection) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    groupedList
                } else {
                    searchList
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first { store.selectedID = id }
            }
        }
        .onChange(of: selection) { _, new in
            if new.count == 1, let id = new.first, store.selectedID != id { store.selectedID = id }
        }
        .onChange(of: store.selectedID) { _, new in
            if let id = new, !selection.contains(id) || selection.count != 1 && selection.isEmpty { selection = [id] }
        }
        .onChange(of: store.sidebarSearchFocus) { _, _ in searchFocused = true }
        .onAppear { if let id = store.selectedID { selection = [id] } }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("新对话") { store.newConversation() }
                    Button("新建分组…") { folderSheet = FolderSheet(folder: nil, moving: []) }
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                } primaryAction: {
                    store.newConversation()
                }
                .help("新对话（⌘N）")
            }
            ToolbarItem {
                SettingsLink { Label("设置", systemImage: "gearshape") }.help("设置（⌘,）")
            }
        }
        .sheet(item: $renaming) { c in
            SessionEditSheet(conversation: c)
        }
        .sheet(item: $folderSheet) { fs in
            FolderEditSheet(request: fs)
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.deleteConversations(pendingDelete)
                selection.subtract(pendingDelete)
                pendingDelete = []
            }
            Button("取消", role: .cancel) { pendingDelete = [] }
        } message: {
            let info = store.deleteInfo(pendingDelete)
            Text("将删除 \(info.count) 个对话，共 \(info.messages) 条消息" + (info.images > 0 ? "、\(info.images) 张图片" : "") + "。此操作不可撤销。")
        }
    }

    private var deleteTitle: String {
        pendingDelete.count > 1 ? "删除 \(pendingDelete.count) 个对话？" : "删除这个对话？"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索对话（⇧⌘F）", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Grouped

    @ViewBuilder private var groupedList: some View {
        let groups = SidebarGrouping.group(store.conversations, folders: store.folders)
        ForEach(groups, id: \.0.id) { section, convs in
            switch section {
            case .pinned:
                Section("置顶") { rows(convs, terms: []) }
            case .bucket(let b):
                Section(b.title) { rows(convs, terms: []) }
            case .folder(let fid):
                if let f = store.folder(fid) {
                    Section {
                        if expanded.contains(fid.uuidString) { rows(convs, terms: []) }
                    } header: {
                        FolderHeader(folder: f, conversations: convs,
                                     expanded: expanded.contains(fid.uuidString),
                                     toggle: { setExpanded(fid, !expanded.contains(fid.uuidString)) },
                                     edit: { folderSheet = FolderSheet(folder: f, moving: []) })
                    }
                }
            }
        }
        Section {
            Color.clear.frame(height: 1)
                .dropDestination(for: String.self) { items, _ in
                    store.move(Set(items.compactMap(UUID.init(uuidString:))), to: nil); return true
                }
        }
    }

    // MARK: Search

    @ViewBuilder private var searchList: some View {
        let hits = SessionSearch.search(store.conversations, query: query)
        let terms = SessionSearch.terms(query)
        if hits.isEmpty {
            Text("没有找到「\(query)」").foregroundStyle(.secondary)
        } else {
            Section("\(hits.count) 个结果") {
                ForEach(hits) { h in
                    if let c = store.conversation(h.conversationID) {
                        SessionRow(conversation: c, snippet: h.snippet, terms: terms).tag(c.id)
                    }
                }
            }
        }
    }

    @ViewBuilder private func rows(_ convs: [Conversation], terms: [String]) -> some View {
        ForEach(convs) { c in
            SessionRow(conversation: c, snippet: nil, terms: terms)
                .tag(c.id)
                .draggable(c.id.uuidString)
        }
    }

    // MARK: Context menu

    @ViewBuilder private func menu(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first, let c = store.conversation(id) {
            Button(c.isPinned ? "取消置顶" : "置顶") { store.togglePin([id]) }
            Button("编辑标题和图标…") { renaming = c }
            Button("重新生成标题") { store.regenerateTitle(id) }
                .disabled(c.messages.isEmpty || store.titlingIDs.contains(id))
            Button("复制对话") { store.duplicate(id) }
            moveMenu(ids)
            exportMenu(ids)
            Divider()
            Button("清空消息") { store.clear(id) }
            Button("删除…", role: .destructive) { pendingDelete = ids; confirmDelete = true }
        } else if ids.count > 1 {
            Button("置顶 / 取消置顶") { store.togglePin(ids) }
            moveMenu(ids)
            exportMenu(ids)
            Divider()
            Button("删除 \(ids.count) 个对话…", role: .destructive) { pendingDelete = ids; confirmDelete = true }
        }
    }

    @ViewBuilder private func moveMenu(_ ids: Set<UUID>) -> some View {
        Menu("移到分组") {
            ForEach(store.folders) { f in
                Button(f.name) { store.move(ids, to: f.id) }
            }
            if !store.folders.isEmpty { Divider() }
            Button("新建分组…") { folderSheet = FolderSheet(folder: nil, moving: ids) }
            if ids.contains(where: { store.conversation($0)?.folderID != nil }) {
                Button("移出分组") { store.move(ids, to: nil) }
            }
        }
    }

    @ViewBuilder private func exportMenu(_ ids: Set<UUID>) -> some View {
        Menu("导出") {
            ForEach(ExportFormat.allCases) { f in
                Button(f.label) { store.export(ids, format: f) }
            }
        }
    }
}

// MARK: - Row

struct SessionRow: View {
    @EnvironmentObject var store: AppStore
    let conversation: Conversation
    let snippet: String?
    let terms: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                if store.isRunning(conversation.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: conversation.icon ?? "bubble.left")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(highlight(conversation.title.isEmpty ? Conversation.defaultTitle : conversation.title))
                        .lineLimit(1)
                    if conversation.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    Text(SidebarGrouping.relative(conversation.updatedAt))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(highlight(snippet ?? SidebarGrouping.preview(conversation)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .overlay {
            if store.titlingIDs.contains(conversation.id) {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func highlight(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard !terms.isEmpty else { return a }
        for r in SessionSearch.hitRanges(in: s, terms: terms) {
            let lo = s.distance(from: s.startIndex, to: r.lowerBound)
            let len = s.distance(from: r.lowerBound, to: r.upperBound)
            let ai = a.index(a.startIndex, offsetByCharacters: lo)
            let aj = a.index(ai, offsetByCharacters: len)
            a[ai..<aj].backgroundColor = .yellow.opacity(0.45)
            a[ai..<aj].foregroundColor = .primary
        }
        return a
    }
}

// MARK: - Folder header

struct FolderHeader: View {
    @EnvironmentObject var store: AppStore
    let folder: ChatFolder
    let conversations: [Conversation]
    let expanded: Bool
    let toggle: () -> Void
    let edit: () -> Void
    @State private var confirmDeleteAll = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
            Image(systemName: folder.icon ?? "folder")
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name).font(.callout.bold()).foregroundStyle(.primary)
                if !expanded, let first = conversations.first {
                    Text("\(conversations.count) 个对话 · \(first.title)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if conversations.isEmpty {
                    Text("空分组").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if folder.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
            Spacer()
            if conversations.contains(where: { store.isRunning($0.id) }) {
                ProgressView().controlSize(.mini)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .dropDestination(for: String.self) { items, _ in
            store.move(Set(items.compactMap(UUID.init(uuidString:))), to: folder.id); return true
        }
        .contextMenu {
            Button("在此分组新建对话") { store.newConversation(inFolder: folder.id) }
            Button(folder.isPinned ? "取消置顶分组" : "置顶分组") { store.toggleFolderPin(folder.id) }
            Button("重命名…", action: edit)
            exportMenu
            Divider()
            Button("解散分组（保留对话）") { store.dissolveFolder(folder.id) }
            Button("删除分组及其中对话…", role: .destructive) { confirmDeleteAll = true }
        }
        .confirmationDialog("删除分组「\(folder.name)」及其中 \(conversations.count) 个对话？",
                            isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.deleteFolderWithSessions(folder.id) }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作不可撤销。") }
    }

    private var exportMenu: some View {
        Menu("导出全部") {
            ForEach(ExportFormat.allCases) { f in
                Button(f.label) { store.export(Set(conversations.map(\.id)), format: f) }
            }
        }
        .disabled(conversations.isEmpty)
    }
}

// MARK: - Sheets

let sessionIcons = ["bubble.left", "terminal", "doc.text", "globe", "hammer", "chart.bar", "book",
                    "lightbulb", "briefcase", "graduationcap", "paintbrush", "music.note", "heart", "star"]

struct SessionEditSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var title = ""
    @State private var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑对话").font(.headline)
            TextField("标题", text: $title).textFieldStyle(.roundedBorder)
            IconGrid(selection: $icon)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.rename(conversation.id, title: title, icon: icon); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { title = conversation.title; icon = conversation.icon }
    }
}

struct IconGrid: View {
    @Binding var selection: String?
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 7), spacing: 6) {
            ForEach(sessionIcons, id: \.self) { name in
                Image(systemName: name)
                    .frame(width: 28, height: 28)
                    .background((selection ?? "bubble.left") == name ? Color.accentColor.opacity(0.25) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = name == "bubble.left" ? nil : name }
            }
        }
    }
}

struct FolderSheet: Identifiable {
    let id = UUID()
    let folder: ChatFolder?
    let moving: Set<UUID>
}

struct FolderEditSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: FolderSheet
    @State private var name = ""
    @State private var icon: String? = nil
    @State private var conflict: ChatFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.folder == nil ? "新建分组" : "重命名分组").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            IconGrid(selection: $icon)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.folder == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = request.folder?.name ?? ""; icon = request.folder?.icon }
        .alert("已有同名分组「\(conflict?.name ?? "")」", isPresented: Binding(get: { conflict != nil },
                                                                     set: { if !$0 { conflict = nil } })) {
            Button("合并到已有分组") {
                if let src = request.folder, let dst = conflict { store.mergeFolder(src.id, into: dst.id) }
                conflict = nil; dismiss()
            }
            Button("取消", role: .cancel) { conflict = nil }
        } message: {
            Text("可以把当前分组的对话合并过去，或换一个名字。")
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let f = request.folder {
            if let c = store.renameFolder(f.id, name: n, icon: icon) { conflict = c; return }
        } else if let existing = store.findFolder(named: n) {
            store.move(request.moving, to: existing.id)
        } else {
            _ = store.createFolder(name: n, icon: icon, moving: request.moving)
        }
        dismiss()
    }
}
