import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let id = store.selectedID, store.conversation(id) != nil {
                ChatView(conversationID: id)
                    .id(id)
            } else {
                Text("选择或新建一个对话")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelControls()
            }
        }
    }
}

struct ModelControls: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let cid = store.selectedID
        HStack(spacing: 8) {
            Picker("模型分组", selection: Binding<UUID?>(
                get: { store.group(for: cid)?.id },
                set: { gid in
                    if let cid { store.setGroup(gid, for: cid) } else { store.settings.activeGroupID = gid }
                }
            )) {
                ForEach(store.settings.groups) { g in
                    Text(groupTitle(g)).tag(Optional(g.id))
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 160)
            .help("当前对话使用的模型分组")

            Picker("思考", selection: Binding<ThinkingLevel>(
                get: { store.thinking(for: cid) },
                set: { t in
                    if let cid { store.setThinking(t, for: cid) } else { store.settings.defaultThinkingLevel = t }
                }
            )) {
                ForEach(ThinkingLevel.allCases) { t in
                    Text("思考：\(t.label)").tag(t)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 110)
            .help("思考档位（会按模型能力自动收敛）")
        }
    }

    private func groupTitle(_ g: ModelGroup) -> String {
        let first = g.members.first(where: { store.isAvailable($0) }).flatMap { store.entry($0) }
        if let e = first { return "\(g.name) · \(e.displayName)" }
        return "\(g.name)（无可用模型）"
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        List(selection: $store.selectedID) {
            ForEach(store.conversations) { c in
                HStack(spacing: 6) {
                    if store.isRunning(c.id) {
                        ProgressView().controlSize(.small)
                    }
                    Text(c.title)
                        .lineLimit(1)
                }
                .tag(c.id)
                .contextMenu {
                    Button("清空消息") { store.clear(c.id) }
                    Divider()
                    Button("删除对话", role: .destructive) { store.delete(c.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    store.newConversation()
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .help("新对话（⌘N）")
            }
            ToolbarItem {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置（⌘,）")
            }
        }
    }
}
