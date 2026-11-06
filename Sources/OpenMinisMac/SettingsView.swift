import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettings()
                .tabItem { Label("模型服务", systemImage: "cpu") }
            GroupsSettings()
                .tabItem { Label("模型分组", systemImage: "square.stack.3d.up") }
            MemorySettings()
                .tabItem { Label("记忆", systemImage: "brain") }
            SoulSettings()
                .tabItem { Label("人格", systemImage: "person.crop.circle") }
            SkillsSettings()
                .tabItem { Label("技能", systemImage: "puzzlepiece") }
            UsageSettings()
                .tabItem { Label("用量", systemImage: "chart.bar") }
            MemorySettings()
                .tabItem { Label("记忆", systemImage: "brain") }
            SoulSettings()
                .tabItem { Label("人格", systemImage: "person.crop.circle") }
            SkillsSettings()
                .tabItem { Label("技能", systemImage: "puzzlepiece.extension") }
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 820, height: 580)
    }
}

// MARK: - Binding helpers

enum FieldBinding {
    static func int(_ b: Binding<Int?>) -> Binding<String> {
        Binding(get: { b.wrappedValue.map(String.init) ?? "" },
                set: { b.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) })
    }
    static func double(_ b: Binding<Double?>) -> Binding<String> {
        Binding(get: { b.wrappedValue.map { String($0) } ?? "" },
                set: { b.wrappedValue = Double($0.trimmingCharacters(in: .whitespaces)) })
    }
    static func string(_ b: Binding<String?>) -> Binding<String> {
        Binding(get: { b.wrappedValue ?? "" },
                set: { let t = $0.trimmingCharacters(in: .whitespaces); b.wrappedValue = t.isEmpty ? nil : $0 })
    }
    /// "key: value" per line.
    static func dict(_ b: Binding<[String: String]>) -> Binding<String> {
        Binding(get: { b.wrappedValue.keys.sorted().map { "\($0): \(b.wrappedValue[$0]!)" }.joined(separator: "\n") },
                set: { text in
                    var d: [String: String] = [:]
                    for line in text.components(separatedBy: "\n") {
                        guard let r = line.range(of: ":") else { continue }
                        let k = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                        let v = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty { d[k] = v }
                    }
                    b.wrappedValue = d
                })
    }
}

// MARK: - Providers

struct ProvidersSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.settings.instances) { inst in
                        HStack {
                            Circle()
                                .fill(inst.isEnabled && inst.hasCredential ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(inst.label)
                                Text(inst.type.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(inst.id)
                    }
                }
                HStack {
                    Menu {
                        ForEach(ProviderInstance.presets, id: \.label) { p in
                            Button(p.label) {
                                var n = p
                                n.id = UUID()
                                store.settings.instances.append(n)
                                selection = n.id
                            }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 32)
                    Button {
                        guard let id = selection else { return }
                        selection = nil
                        store.removeInstance(id)
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 210)

            Divider()

            if let id = selection, let idx = store.settings.instances.firstIndex(where: { $0.id == id }) {
                InstanceEditor(inst: $store.settings.instances[idx])
                    .id(id)
            } else {
                Text("选择或添加一个模型服务")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.settings.instances.first?.id } }
    }
}

struct InstanceEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var inst: ProviderInstance
    @State private var apiKey = ""
    @State private var loaded = false
    @State private var newModel = ""
    @State private var editingEntry: String?
    @State private var filter = ""

    private var entries: [ModelEntry] {
        store.settings.entries.filter { e in
            e.instanceID == inst.id && (filter.isEmpty || e.modelID.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        Form {
            Section("连接") {
                TextField("名称", text: $inst.label)
                Picker("协议", selection: $inst.type) {
                    ForEach(ProviderType.allCases) { t in Text(t.label).tag(t) }
                }
                TextField("Base URL", text: $inst.customBaseURL, prompt: Text(inst.type.defaultBaseURL))
                if inst.type.isOpenAIFamily {
                    Toggle("自动补全 /v1", isOn: $inst.appendV1Suffix)
                    Toggle("Azure 模式（api-key 头）", isOn: $inst.azureMode)
                }
                Text("实际地址：\(inst.effectiveBaseURL)").font(.caption).foregroundStyle(.secondary)
                SecureField("API Key", text: $apiKey)
                    .onChange(of: apiKey) { _, v in
                        if loaded { Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: inst.keychainAccount) }
                    }
                TextField("自定义 User-Agent", text: $inst.customUserAgent, prompt: Text("OpenMinisMac/1.0"))
                Toggle("启用", isOn: $inst.isEnabled)
            }

            Section {
                HStack {
                    Button {
                        Task { await store.refreshModels(inst.id) }
                    } label: {
                        Label("拉取模型列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.fetchingInstances.contains(inst.id))
                    if store.fetchingInstances.contains(inst.id) { ProgressView().controlSize(.small) }
                    Spacer()
                    TextField("筛选", text: $filter).frame(width: 140)
                }
                if let err = store.fetchErrors[inst.id] {
                    Text(err).font(.caption).foregroundStyle(Color.red).textSelection(.enabled)
                }
                HStack {
                    TextField("手动添加模型 ID", text: $newModel)
                    Button("添加") { addModel() }
                        .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(entries) { e in
                    EntryRow(entry: e, onEdit: { editingEntry = e.id })
                }
            } header: {
                Text("模型（勾选的会出现在分组里）")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = Keychain.get(inst.keychainAccount) ?? ""
            DispatchQueue.main.async { loaded = true }
        }
        .sheet(item: Binding(get: { editingEntry.map(SheetID.init) }, set: { editingEntry = $0?.id })) { s in
            EntryEditor(entryID: s.id).environmentObject(store)
        }
    }

    private func addModel() {
        let m = newModel.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        if !store.settings.entries.contains(where: { $0.instanceID == inst.id && $0.modelID == m }) {
            store.settings.entries.append(ModelEntry(instanceID: inst.id, modelID: m, isCustom: true))
        }
        newModel = ""
    }
}

struct SheetID: Identifiable { let id: String }

struct EntryRow: View {
    @EnvironmentObject var store: AppStore
    let entry: ModelEntry
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !entry.isHidden },
                set: { v in
                    if let i = store.settings.entries.firstIndex(where: { $0.id == entry.id }) {
                        store.settings.entries[i].isHidden = !v
                    }
                }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    if entry.displayName != entry.modelID { Text(entry.modelID) }
                    if let c = entry.contextWindow { Text("\(c / 1000)K") }
                    if entry.info.reasoning == true { Text("思考") }
                    if entry.info.imageInput == true { Text("图片") }
                    if let ci = entry.info.costInput, let co = entry.info.costOutput {
                        Text(String(format: "$%.2f/$%.2f", ci, co))
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(store.settings.groups) { g in
                    let inGroup = g.members.contains(entry.id)
                    Button(inGroup ? "✓ \(g.name)" : g.name) { toggle(group: g.id) }
                }
            } label: { Image(systemName: "square.stack.3d.up") }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .help("加入或移出分组")
            Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("模型参数")
            Button { store.removeEntry(entry.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("删除")
        }
    }

    private func toggle(group gid: UUID) {
        guard let gi = store.settings.groups.firstIndex(where: { $0.id == gid }) else { return }
        if let mi = store.settings.groups[gi].members.firstIndex(of: entry.id) {
            store.settings.groups[gi].members.remove(at: mi)
        } else {
            store.settings.groups[gi].members.append(entry.id)
            if let i = store.settings.entries.firstIndex(where: { $0.id == entry.id }) {
                store.settings.entries[i].isHidden = false
            }
        }
    }
}

struct EntryEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let entryID: String

    var body: some View {
        VStack(spacing: 0) {
            if let i = store.settings.entries.firstIndex(where: { $0.id == entryID }) {
                let o = $store.settings.entries[i].overrides
                let e = store.settings.entries[i]
                Form {
                    Section("\(e.modelID)") {
                        TextField("显示名称", text: FieldBinding.string(o.displayName), prompt: Text(e.info.name ?? e.modelID))
                        TextField("上下文窗口（tokens）", text: FieldBinding.int(o.contextWindow),
                                  prompt: Text(e.info.contextWindow.map(String.init) ?? "未知"))
                        TextField("最大输出（tokens）", text: FieldBinding.int(o.maxOutputTokens),
                                  prompt: Text(e.info.maxOutput.map(String.init) ?? "默认"))
                        Picker("支持思考", selection: o.supportsReasoning) {
                            Text("自动").tag(Bool?.none)
                            Text("是").tag(Bool?.some(true))
                            Text("否").tag(Bool?.some(false))
                        }
                        Picker("支持图片输入", selection: o.supportsImages) {
                            Text("自动").tag(Bool?.none)
                            Text("是").tag(Bool?.some(true))
                            Text("否").tag(Bool?.some(false))
                        }
                        Picker("思考档位上限", selection: o.maxThinkingLevel) {
                            Text("自动（\(e.thinkingCeiling.label)）").tag(ThinkingLevel?.none)
                            ForEach(ThinkingLevel.allCases.filter { $0 != .off }) { t in
                                Text(t.label).tag(ThinkingLevel?.some(t))
                            }
                        }
                        TextField("temperature", text: FieldBinding.double(o.temperature), prompt: Text("默认"))
                        TextField("top_p", text: FieldBinding.double(o.topP), prompt: Text("默认"))
                    }
                    Section("自定义请求头（每行 key: value）") {
                        TextEditor(text: FieldBinding.dict(o.customHeaders))
                            .font(.body.monospaced()).frame(height: 60)
                    }
                    Section("额外请求体参数（每行 key: value，值可写 JSON）") {
                        TextEditor(text: FieldBinding.dict(o.extraBody))
                            .font(.body.monospaced()).frame(height: 60)
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("模型已删除").padding()
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
    }
}

// MARK: - Groups

struct GroupsSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.settings.groups) { g in
                        HStack {
                            Text(g.name)
                            Spacer()
                            if g.id == store.group(for: nil)?.id {
                                Text("默认").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(g.id)
                    }
                }
                HStack {
                    Button {
                        let g = ModelGroup(name: "新分组")
                        store.settings.groups.append(g)
                        selection = g.id
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    Button {
                        guard let id = selection else { return }
                        selection = nil
                        store.settings.groups.removeAll { $0.id == id }
                        if store.settings.activeGroupID == id { store.settings.activeGroupID = store.settings.groups.first?.id }
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 210)

            Divider()

            if let id = selection, let idx = store.settings.groups.firstIndex(where: { $0.id == id }) {
                GroupEditor(group: $store.settings.groups[idx]).id(id)
            } else {
                Text("选择或新建一个分组")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.settings.groups.first?.id } }
    }
}

struct GroupEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var group: ModelGroup

    private var candidates: [ModelEntry] {
        store.settings.entries.filter { !$0.isHidden && !group.members.contains($0.id) }
    }

    var body: some View {
        Form {
            Section("分组") {
                TextField("名称", text: $group.name)
                Picker("路由策略", selection: $group.strategy) {
                    ForEach(GroupStrategy.allCases) { s in Text(s.label).tag(s) }
                }
                Picker("回退策略", selection: $group.fallbackPolicy) {
                    ForEach(FallbackPolicy.allCases) { s in Text(s.label).tag(s) }
                }
                Picker("默认思考档位", selection: $group.defaultThinkingLevel) {
                    Text("跟随全局").tag(ThinkingLevel?.none)
                    ForEach(ThinkingLevel.allCases) { t in Text(t.label).tag(ThinkingLevel?.some(t)) }
                }
                TextField("上下文上限（tokens，留空不限）", text: FieldBinding.int($group.contextLimitTokens))
                Button("设为默认分组") { store.settings.activeGroupID = group.id }
                    .disabled(store.settings.activeGroupID == group.id)
            }
            Section {
                ForEach(Array(group.members.enumerated()), id: \.element) { i, mid in
                    HStack {
                        Text("\(i + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        if let e = store.entry(mid) {
                            Circle().fill(store.isAvailable(mid) ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(store.entryLabel(e)).lineLimit(1)
                        } else {
                            Text("（已删除）\(mid)").foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless).disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless).disabled(i == group.members.count - 1)
                        Button { group.members.remove(at: i) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("添加模型") {
                    ForEach(candidates) { e in
                        Button(store.entryLabel(e)) { group.members.append(e.id) }
                    }
                }
                .disabled(candidates.isEmpty)
            } header: {
                Text("成员（按顺序尝试；灰点表示服务未启用或缺少 Key）")
            }
        }
        .formStyle(.grouped)
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard group.members.indices.contains(j) else { return }
        group.members.swapAt(i, j)
    }
}

// MARK: - Usage

struct UsageSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var range = 1

    private struct Row: Identifiable {
        var id: String { label }
        var label: String
        var calls: Int
        var usage: TokenUsage
    }

    private var rows: [Row] {
        let cutoff: Date? = {
            switch range {
            case 0: return Calendar.current.startOfDay(for: Date())
            case 1: return Date().addingTimeInterval(-7 * 86400)
            case 2: return Date().addingTimeInterval(-30 * 86400)
            default: return nil
            }
        }()
        var agg: [String: Row] = [:]
        for r in store.usageLog where cutoff == nil || r.date >= cutoff! {
            var row = agg[r.label] ?? Row(label: r.label, calls: 0, usage: TokenUsage())
            row.calls += 1
            row.usage = row.usage + r.usage
            agg[r.label] = row
        }
        return agg.values.sorted { $0.usage.input + $0.usage.output > $1.usage.input + $1.usage.output }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $range) {
                    Text("今天").tag(0)
                    Text("7 天").tag(1)
                    Text("30 天").tag(2)
                    Text("全部").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
                Button("清空记录", role: .destructive) { store.clearUsage() }
            }
            let rs = rows
            if rs.isEmpty {
                Text("暂无用量记录").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("模型").gridColumnAlignment(.leading)
                            Text("请求"); Text("输入"); Text("输出"); Text("缓存读"); Text("思考")
                        }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        Divider()
                        ForEach(rs) { r in
                            GridRow {
                                Text(r.label).lineLimit(1)
                                Text("\(r.calls)")
                                Text(UsageSettings.fmt(r.usage.input))
                                Text(UsageSettings.fmt(r.usage.output))
                                Text(UsageSettings.fmt(r.usage.cacheRead))
                                Text(UsageSettings.fmt(r.usage.reasoning))
                            }
                            .font(.callout.monospacedDigit())
                        }
                        Divider()
                        let total = rs.reduce(TokenUsage()) { $0 + $1.usage }
                        GridRow {
                            Text("合计").bold()
                            Text("\(rs.reduce(0) { $0 + $1.calls })")
                            Text(UsageSettings.fmt(total.input))
                            Text(UsageSettings.fmt(total.output))
                            Text(UsageSettings.fmt(total.cacheRead))
                            Text(UsageSettings.fmt(total.reasoning))
                        }
                        .font(.callout.monospacedDigit().bold())
                    }
                    .padding(4)
                }
            }
        }
        .padding(20)
    }

    static func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
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
