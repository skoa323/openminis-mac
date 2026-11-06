import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettings()
                .tabItem { Label("模型服务", systemImage: "cpu") }
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 680, height: 460)
    }
}

struct ProvidersSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.settings.profiles) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.id == store.activeProfile?.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .tag(p.id)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        ForEach(ProviderProfile.presets) { p in
                            Button(p.name) {
                                store.settings.profiles.append(p)
                                selection = p.id
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)

                    Button {
                        guard let id = selection else { return }
                        selection = nil
                        Keychain.delete(id.uuidString)
                        store.settings.profiles.removeAll { $0.id == id }
                        if store.settings.activeProfileID == id {
                            store.settings.activeProfileID = store.settings.profiles.first?.id
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 200)

            Divider()

            if let id = selection, let idx = store.settings.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditor(profile: $store.settings.profiles[idx])
                    .id(id)
            } else {
                Text("选择左侧的服务进行编辑，或点 + 添加")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.activeProfile?.id } }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var profile: ProviderProfile
    @State private var apiKey = ""
    @State private var loaded = false

    var body: some View {
        Form {
            TextField("名称", text: $profile.name)
            Picker("接口类型", selection: $profile.kind) {
                ForEach(ProviderKind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            TextField("Base URL", text: $profile.baseURL)
                .font(.body.monospaced())
            TextField("模型", text: $profile.model)
                .font(.body.monospaced())
            SecureField("API Key", text: $apiKey)
                .onChange(of: apiKey) { _, newValue in
                    guard loaded else { return }
                    let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if v.isEmpty { Keychain.delete(profile.id.uuidString) }
                    else { Keychain.set(v, for: profile.id.uuidString) }
                }
            Text("API Key 保存在系统钥匙串中。OpenAI 兼容接口填到 /v1 为止，例如 https://api.openai.com/v1。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                if store.activeProfile?.id == profile.id {
                    Label("正在使用", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("设为当前") { store.settings.activeProfileID = profile.id }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = Keychain.get(profile.id.uuidString) ?? ""
            DispatchQueue.main.async { loaded = true }
        }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("工作区") {
                HStack {
                    TextField("目录", text: $store.settings.workspacePath)
                        .font(.body.monospaced())
                    Button("选择…") { pickFolder() }
                    Button {
                        try? FileManager.default.createDirectory(at: store.workspaceURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.workspaceURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在 Finder 中打开")
                }
                Text("shell 的默认目录，相对路径以此为基准。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("安全") {
                Toggle("执行 shell 命令前需要确认", isOn: $store.settings.confirmShell)
                Stepper("单轮最多工具调用：\(store.settings.maxIterations) 次",
                        value: $store.settings.maxIterations, in: 5...200, step: 5)
            }
            Section("附加系统提示词") {
                TextEditor(text: $store.settings.customPrompt)
                    .font(.body)
                    .frame(minHeight: 80)
            }
            Section("数据") {
                HStack {
                    Text("对话、设置与长期记忆保存在 Application Support/OpenMinisMac")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开") { NSWorkspace.shared.open(AppStore.supportDir) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.workspaceURL
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.workspacePath = url.path
        }
    }
}
