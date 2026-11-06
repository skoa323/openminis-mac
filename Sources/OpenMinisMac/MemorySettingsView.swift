import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Settings → 记忆 / 人格 / 技能 (upstream MemoryManagementView, SoulSettingsView, SkillsManagementView),
// plus the per-conversation "记忆与技能" popover (SessionMemoryView / SessionSkillsView).

// MARK: - Memory

struct MemorySettings: View {
    @EnvironmentObject var store: AppStore
    @State private var files: [URL] = []
    @State private var selection: URL?
    @State private var text = ""
    @State private var dirty = false
    @State private var confirmDelete: URL?

    private func refresh() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: MemoryStore.globalFile.path) {
            try? "".write(to: MemoryStore.globalFile, atomically: true, encoding: .utf8)
        }
        files = [MemoryStore.globalFile] + MemoryStore.dailyFiles()
        if selection == nil || !files.contains(selection!) { selection = files.first }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("新对话默认开启记忆", isOn: $store.settings.memoryDefault)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.open(MemoryStore.root) }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
            }
            Text("开启后会注入 GLOBAL.md 和最近 3 天的日志，并提供 memory_write / memory_get。单个对话可用 /memory 切换。")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(selection: $selection) {
                    ForEach(files, id: \.self) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.lastPathComponent).font(.body.monospaced())
                            Text(preview(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(f)
                        .contextMenu {
                            if f != MemoryStore.globalFile {
                                Button("删除", role: .destructive) { confirmDelete = f }
                            }
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 230)

                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .onChange(of: text) { _, _ in dirty = true }
                    HStack {
                        if let s = selection { Text(sizeLabel(s)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("保存") { save() }.disabled(!dirty).keyboardShortcut("s", modifiers: .command)
                    }
                }
                .padding(.leading, 6)
            }
        }
        .padding()
        .onAppear { refresh(); load() }
        .onChange(of: selection) { _, _ in load() }
        .confirmationDialog("删除这个记忆文件？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let f = confirmDelete { try? FileManager.default.removeItem(at: f) }
                confirmDelete = nil; selection = nil; refresh(); load()
            }
        }
    }

    private func load() {
        text = selection.map(MemoryStore.read) ?? ""
        DispatchQueue.main.async { dirty = false }
    }
    private func save() {
        guard let s = selection else { return }
        try? text.write(to: s, atomically: true, encoding: .utf8)
        dirty = false
    }
    private func preview(_ f: URL) -> String {
        let t = MemoryStore.read(f).components(separatedBy: "\n").first { l in
            let x = l.trimmingCharacters(in: .whitespaces); return !x.isEmpty && !x.hasPrefix("<!--")
        }
        return t ?? "（空）"
    }
    private func sizeLabel(_ f: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: f.path)
        let n = (a?[.size] as? NSNumber)?.intValue ?? 0
        let d = a?[.modificationDate] as? Date
        return "\(n) 字节" + (d.map { " · " + SessionExport.stamp.string(from: $0) } ?? "")
    }
}

// MARK: - SOUL

struct SoulSettings: View {
    @State private var soul = SoulStore.load()
    @State private var saved = SoulStore.load()
    @State private var confirmReset = false
    @State private var error: String?

    var body: some View {
        let tokens = Soul.tokenCount(soul.body)
        Form {
            Section("身份") {
                TextField("名字", text: $soul.name)
                HStack {
                    TextField("图标（emoji）", text: $soul.icon)
                    Button("选择图片…") { pickIcon() }
                    if !soul.icon.isEmpty { Button("清除") { soul.icon = "" } }
                }
                TextField("回复风格（style，可留空）", text: $soul.style)
                TextField("语言（lang）", text: $soul.lang)
            }
            Section {
                TextEditor(text: $soul.body).font(.body.monospaced()).frame(minHeight: 200)
                HStack {
                    Text("\(tokens) / \(Soul.maxBodyTokens) token")
                        .font(.caption).foregroundStyle(tokens > Soul.maxBodyTokens ? Color.red : Color.green)
                    Spacer()
                }
            } header: {
                Text("人格正文（注入到系统提示最前面；与用户最新指示冲突时以用户为准）")
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("恢复默认", role: .destructive) { confirmReset = true }
                Spacer()
                Button("保存") { save() }
                    .disabled(soul == saved || soul.bodyTooLong)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("恢复默认人格？当前内容会被覆盖。", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) { soul = Soul(); save() }
        }
    }

    private func save() {
        do { try SoulStore.save(soul); saved = soul; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func pickIcon() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url,
              let name = Attachments.save(fileURL: u),
              let b64 = Attachments.base64(name) else { return }
        soul.icon = "data:image/jpeg;base64," + b64
    }
}

// MARK: - Skills

struct SkillsSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: String?
    @State private var showImport = false
    @State private var confirmDelete: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.skills) { s in
                        HStack {
                            Toggle("", isOn: Binding(get: { s.isEnabled },
                                                     set: { store.setSkillGlobal(s.id, enabled: $0) }))
                                .labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                Text("\(s.version) · \(store.usageTier(s))\(s.source == "bundled" ? " · 内置" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(s.id)
                        .contextMenu { Button("删除", role: .destructive) { confirmDelete = s.id } }
                    }
                }
                if store.skills.isEmpty {
                    Text("还没有技能。点「导入」添加，或让模型按 skill-creator 写一个。")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
                Divider()
                HStack {
                    Button { showImport = true } label: { Label("导入", systemImage: "square.and.arrow.down") }
                    Button { store.reloadSkills() } label: { Image(systemName: "arrow.clockwise") }.help("重新扫描")
                    Spacer()
                    Button { NSWorkspace.shared.open(SkillLibrary.root) } label: { Image(systemName: "folder") }
                        .help("打开技能目录")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 230, idealWidth: 260)

            Group {
                if let sid = selection, let s = store.skills.first(where: { $0.id == sid }) {
                    SkillDetail(skill: s, onDelete: { confirmDelete = s.id })
                        .id(s.id)
                } else {
                    Text("选择一个技能").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showImport) { ImportSkillSheet() }
        .confirmationDialog("删除这个技能及其全部文件？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let id = confirmDelete { store.deleteSkill(id) }
                if selection == confirmDelete { selection = nil }
                confirmDelete = nil
            }
        }
    }
}

struct SkillDetail: View {
    @EnvironmentObject var store: AppStore
    let skill: SkillMeta
    let onDelete: () -> Void
    @State private var files: [String] = []
    @State private var file = "SKILL.md"
    @State private var text = ""
    @State private var dirty = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(skill.name).font(.title3.bold())
                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    if skill.source.hasPrefix("url:") {
                        Text(String(skill.source.dropFirst(4))).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                Spacer()
                Menu("更多") {
                    if skill.source.hasPrefix("url:") { Button("从 URL 更新") { update() } }
                    Button("导出为 .zip…") { export() }
                    Button("在 Finder 中显示") { NSWorkspace.shared.open(SkillLibrary.dir(skill.id)) }
                    Divider()
                    Button("删除", role: .destructive, action: onDelete)
                }
                .fixedSize()
            }
            Picker("文件", selection: $file) {
                ForEach(files, id: \.self) { Text($0).tag($0) }
            }
            TextEditor(text: $text).font(.body.monospaced())
                .onChange(of: text) { _, _ in dirty = true }
            HStack {
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("保存") { save() }.disabled(!dirty)
            }
        }
        .padding()
        .onAppear { listFiles(); load() }
        .onChange(of: file) { _, _ in load() }
    }

    private func listFiles() {
        let base = SkillLibrary.dir(skill.id)
        var out: [String] = []
        if let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(String(u.path.dropFirst(base.path.count + 1)))
            }
        }
        files = ["SKILL.md"] + out.filter { $0 != "SKILL.md" && !$0.hasPrefix(".") }.sorted()
    }
    private func load() {
        text = MemoryStore.read(SkillLibrary.dir(skill.id).appendingPathComponent(file))
        DispatchQueue.main.async { dirty = false }
    }
    private func save() {
        let u = SkillLibrary.dir(skill.id).appendingPathComponent(file)
        do {
            try text.write(to: u, atomically: true, encoding: .utf8)
            dirty = false; status = "已保存"
            if file == "SKILL.md" { store.reloadSkills() }
        } catch { status = error.localizedDescription }
    }
    private func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = skill.id + ".zip"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try SkillLibrary.exportZip(skill.id, to: u); status = "已导出" }
        catch { status = error.localizedDescription }
    }
    private func update() {
        let url = String(skill.source.dropFirst(4))
        status = "正在更新…"
        Task {
            do { _ = try await SkillLibrary.importGitHub(url); store.reloadSkills(); listFiles(); load(); status = "已更新" }
            catch { status = error.localizedDescription }
        }
    }
}

struct ImportSkillSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    enum Mode: String, CaseIterable, Identifiable { case github, text, file; var id: String { rawValue } }
    @State private var mode: Mode = .github
    @State private var url = ""
    @State private var pasted = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入技能").font(.headline)
            Picker("", selection: $mode) {
                Text("GitHub 链接").tag(Mode.github)
                Text("粘贴 SKILL.md").tag(Mode.text)
                Text("本地文件").tag(Mode.file)
            }
            .pickerStyle(.segmented).labelsHidden()

            switch mode {
            case .github:
                TextField("https://github.com/owner/repo/tree/main/skills/xxx", text: $url)
                Text("会连同该目录下的脚本和参考文件一起下载。").font(.caption).foregroundStyle(.secondary)
            case .text:
                TextEditor(text: $pasted).font(.body.monospaced()).frame(height: 200)
            case .file:
                Text("支持 SKILL.md、技能文件夹、.zip 和 .skill 压缩包（压缩包根目录或一级子目录需含 SKILL.md）。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("选择文件…") { pickFile() }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                if mode != .file {
                    Button("导入") { run() }.disabled(busy).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func done(_ id: String) {
        store.reloadSkills()
        message = "已导入：\(id)"
    }

    private func run() {
        busy = true
        switch mode {
        case .github:
            let u = url.trimmingCharacters(in: .whitespaces)
            Task {
                do { done(try await SkillLibrary.importGitHub(u)) } catch { message = error.localizedDescription }
                busy = false
            }
        case .text:
            do { done(try SkillLibrary.install(skillMD: pasted, source: "file")) } catch { message = error.localizedDescription }
            busy = false
        case .file:
            busy = false
        }
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        guard p.runModal() == .OK, let u = p.url else { return }
        do { done(try SkillLibrary.importFile(u)) } catch { message = error.localizedDescription }
    }
}

// MARK: - Per-conversation popover

struct SessionExtrasButton: View {
    @EnvironmentObject var store: AppStore
    let conversationID: UUID
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("记忆与技能", systemImage: store.memoryEnabled(conversationID) ? "brain.head.profile" : "brain")
        }
        .help("本对话的记忆与技能")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("本对话启用记忆", isOn: Binding(get: { store.memoryEnabled(conversationID) },
                                                set: { store.setMemory($0, for: conversationID) }))
                Divider()
                HStack {
                    Text("技能").font(.headline)
                    Spacer()
                    Button("全部启用") { store.setAllSkills(true, in: conversationID) }
                    Button("全部禁用") { store.setAllSkills(false, in: conversationID) }
                }
                .buttonStyle(.borderless)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.skills) { s in
                            Toggle(isOn: Binding(get: { store.isSkillEnabled(s.id, in: conversationID) },
                                                 set: { store.setSkillOverride(s.id, enabled: $0, in: conversationID) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name)
                                    Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        if store.skills.isEmpty { Text("没有已安装的技能").foregroundStyle(.secondary) }
                    }
                }
                .frame(maxHeight: 260)
            }
            .padding()
            .frame(width: 340)
        }
    }
}
