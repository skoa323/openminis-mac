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
                ProfilePicker()
            }
        }
    }
}

struct ProfilePicker: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Picker("模型", selection: Binding<UUID?>(
            get: { store.activeProfile?.id },
            set: { store.settings.activeProfileID = $0 }
        )) {
            ForEach(store.settings.profiles) { p in
                Text("\(p.name) · \(p.model)").tag(Optional(p.id))
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 180)
        .help("当前使用的模型")
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
