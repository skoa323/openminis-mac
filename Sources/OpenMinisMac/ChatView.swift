import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let conversationID: UUID
    @State private var draft = ""
    @State private var pendingImages: [String] = []
    @State private var dropTargeted = false
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findIndex: Int? = nil

    private var conversation: Conversation? { store.conversation(conversationID) }
    private var running: Bool { store.isRunning(conversationID) }

    // Split out of `body` so the type checker stays fast.
    private var messages: [ChatMessage] { conversation?.messages ?? [] }

    private var toolResults: [String: ChatMessage] {
        var d: [String: ChatMessage] = [:]
        for m in messages where m.role == .tool {
            if let k = m.toolCallId { d[k] = m }
        }
        return d
    }

    private var visibleMessages: [ChatMessage] {
        messages.filter { m in
            switch m.role {
            case .user: return true
            case .assistant: return !(m.content.isEmpty && m.toolCalls.isEmpty && m.reasoning.isEmpty)
            default: return false
            }
        }
    }

    private var showThinking: Bool {
        guard running else { return false }
        guard let last = messages.last else { return true }
        let lastEmpty = last.role != .assistant || (last.content.isEmpty && last.toolCalls.isEmpty && last.reasoning.isEmpty)
        if lastEmpty { return true }
        return store.approval(for: conversationID) == nil && last.role == .tool
    }

    private var findMatches: [FindMatch] {
        findVisible ? ChatFind.matches(visibleMessages, query: findQuery) : []
    }

    private var streamKey: Int {
        let c: Int = messages.last?.content.count ?? 0
        let r: Int = messages.last?.reasoning.count ?? 0
        return c + r
    }

    var body: some View {
        let matches: [FindMatch] = findMatches
        let current: FindMatch? = findIndex.flatMap { $0 < matches.count ? matches[$0] : nil }

        VStack(spacing: 0) {
            if findVisible {
                FindBar(query: $findQuery,
                        label: ChatFind.label(current: findIndex, total: matches.count),
                        onNext: { step(1, matches.count) },
                        onPrev: { step(-1, matches.count) },
                        onClose: { findVisible = false; findQuery = ""; findIndex = nil })
                Divider()
            }
            messageScroller(matches: matches, current: current)
            ActiveJobsBanner(conversationID: conversationID)
            if let a = store.approval(for: conversationID) {
                ApprovalBar(approval: a)
            }
            Divider()
            InputBar(draft: $draft,
                     images: $pendingImages,
                     running: running,
                     onSend: send,
                     onStop: { store.stop(conversationID) })
        }
        .overlay { dropOverlay }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .navigationTitle(conversation?.title ?? "OpenMinis")
    }

    @ViewBuilder private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .background(Color.accentColor.opacity(0.06))
                .overlay(Label("松开以添加图片", systemImage: "photo.badge.plus").font(.title3))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    private func messageScroller(matches: [FindMatch], current: FindMatch?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                messageStack(current: current)
            }
            .onChange(of: messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: streamKey) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: current) { _, m in
                if let m { withAnimation { proxy.scrollTo(m.messageID, anchor: .center) } }
            }
            .onChange(of: findQuery) { _, _ in
                // Land on the newest match, like upstream.
                let n = ChatFind.matches(visibleMessages, query: findQuery).count
                findIndex = n > 0 ? n - 1 : nil
            }
            .onChange(of: store.findEvent) { _, ev in
                guard store.selectedID == conversationID else { return }
                switch ev.kind {
                case .open: findVisible = true
                case .next: step(1, matches.count)
                case .previous: step(-1, matches.count)
                }
            }
        }
    }

    private func messageStack(current: FindMatch?) -> some View {
        let visible = visibleMessages
        let results = toolResults
        let lastID = messages.last?.id
        return LazyVStack(alignment: .leading, spacing: 14) {
            if visible.isEmpty { EmptyChatHint() }
            ForEach(visible) { (m: ChatMessage) in
                let hit: Bool = current?.messageID == m.id
                MessageRow(message: m,
                           results: results,
                           conversationID: conversationID,
                           streaming: running && m.id == lastID)
                    .padding(hit ? 6 : 0)
                    .background(hit ? Color.yellow.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(m.id)
            }
            if showThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("思考中…").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            Color.clear.frame(height: 1).id("bottom")
        }
        .padding(20)
    }

    /// Wraps around; "next" moves toward newer messages.
    private func step(_ d: Int, _ total: Int) {
        guard total > 0 else { findIndex = nil; return }
        let cur = findIndex ?? (d > 0 ? -1 : total)
        findIndex = ((cur + d) % total + total) % total
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty, !running else { return }
        if pendingImages.isEmpty, store.handleSlash(text, in: conversationID) { draft = ""; return }
        let imgs = pendingImages
        draft = ""
        pendingImages = []
        store.send(text, images: imgs, in: conversationID)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, Attachments.imageExtensions.contains(url.pathExtension.lowercased()),
                          let name = Attachments.save(fileURL: url) else { return }
                    DispatchQueue.main.async { pendingImages.append(name) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let name = Attachments.save(img) else { return }
                    DispatchQueue.main.async { pendingImages.append(name) }
                }
            }
        }
        return handled
    }
}

struct EmptyChatHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("OpenMinis for Mac")
                .font(.title2.bold())
            Text("我可以在这台 Mac 上运行命令、读写文件、抓取网页。\n直接告诉我要做什么，也可以粘贴或拖入图片。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - Messages

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct MessageRow: View {
    let message: ChatMessage
    let results: [String: ChatMessage]
    let conversationID: UUID
    let streaming: Bool

    var body: some View {
        if message.role == .user {
            if let cb = AgentCallback.parse(message.content) {
                AgentCallbackCardView(callback: cb)
            } else {
                UserBubble(message: message, conversationID: conversationID)
            }
        } else {
            AssistantRow(message: message, results: results, conversationID: conversationID, streaming: streaming)
        }
    }
}

struct UserBubble: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let conversationID: UUID
    @State private var editing = false
    @State private var editText = ""
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    ImageStrip(names: message.images, size: 120)
                }
                if editing {
                    VStack(alignment: .trailing, spacing: 6) {
                        TextEditor(text: $editText)
                            .font(.body)
                            .frame(minWidth: 320, minHeight: 60, maxHeight: 240)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                        HStack {
                            Button("取消") { editing = false }
                                .keyboardShortcut(.cancelAction)
                            Button("保存并重新发送") {
                                editing = false
                                store.edit(message.id, newText: editText, in: conversationID)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.images.isEmpty)
                        }
                    }
                } else if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if !editing {
                    HStack(spacing: 10) {
                        Button { copyToPasteboard(message.content) } label: { Image(systemName: "doc.on.doc") }
                            .help("复制")
                        Button { startEdit() } label: { Image(systemName: "pencil") }
                            .help("编辑")
                            .disabled(store.isRunning(conversationID))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .opacity(hovering ? 1 : 0)
                }
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("复制") { copyToPasteboard(message.content) }
            Button("编辑") { startEdit() }.disabled(store.isRunning(conversationID))
            Divider()
            Button("从这里分叉") { store.fork(conversationID, at: message.id) }
        }
    }

    private func startEdit() {
        editText = message.content
        editing = true
    }
}

struct AssistantRow: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let results: [String: ChatMessage]
    let conversationID: UUID
    let streaming: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.reasoning.isEmpty {
                ReasoningView(text: message.reasoning,
                              live: streaming && message.content.isEmpty && message.toolCalls.isEmpty)
            }
            if !message.content.isEmpty {
                if message.isError {
                    Label(message.content, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.red)
                        .textSelection(.enabled)
                } else {
                    MarkdownText(text: message.content)
                }
            }
            ForEach(message.toolCalls) { tc in
                ToolCallView(call: tc, result: results[tc.id])
            }
            if !streaming, message.modelLabel != nil || message.usage != nil {
                HStack(spacing: 8) {
                    if let l = message.modelLabel { Text(l) }
                    if let u = message.usage {
                        Text("输入 \(u.input) · 输出 \(u.output)" + (u.cacheRead > 0 ? " · 缓存 \(u.cacheRead)" : ""))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            if !streaming && (!message.content.isEmpty || message.isError) {
                HStack(spacing: 12) {
                    Button { copyToPasteboard(message.content) } label: { Image(systemName: "doc.on.doc") }
                        .help("复制")
                    Button { store.regenerate(message.id, in: conversationID) } label: { Image(systemName: "arrow.clockwise") }
                        .help("重新生成")
                        .disabled(store.isRunning(conversationID))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .opacity(hovering ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("复制") { copyToPasteboard(message.content) }
            Button("重新生成") { store.regenerate(message.id, in: conversationID) }
                .disabled(store.isRunning(conversationID))
            Divider()
            Button("从这里分叉") { store.fork(conversationID, at: message.id) }
        }
    }
}

/// Collapsible reasoning block; open while the model is still thinking, collapsed afterwards
/// unless the user toggled it.
struct ReasoningView: View {
    let text: String
    let live: Bool
    @State private var userExpanded: Bool? = nil

    private var expanded: Bool { userExpanded ?? live }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                userExpanded = !expanded
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Image(systemName: "brain")
                    Text(live ? "思考中…" : "思考过程")
                        .font(.callout)
                    if live { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                    }
            }
        }
    }
}

/// Thumbnails of stored attachments; click opens the full image in Preview.
struct ImageStrip: View {
    let names: [String]
    var size: CGFloat = 80
    var onRemove: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let img = Attachments.image(name) {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    .onTapGesture { NSWorkspace.shared.open(Attachments.url(name)) }
                    .help("点击用预览打开")

                    if let onRemove {
                        Button { onRemove(name) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .help("移除")
                    }
                }
            }
        }
    }
}

// MARK: - Tool calls

struct ToolCallView: View {
    let call: ToolCall
    let result: ChatMessage?
    @State private var expanded = false

    private var icon: String {
        switch call.name {
        case "shell": return "terminal"
        case "read_file": return "doc.text"
        case "write_file", "edit_file": return "square.and.pencil"
        case "list_dir": return "folder"
        case "web_fetch": return "globe"
        case "browser_use": return "safari"
        case "subagent_task": return "person.2.badge.gearshape"
        case "scheduled_task": return "calendar.badge.clock"
        case "memory_write", "memory_get": return "brain"
        default: return "wrench"
        }
    }

    private var args: [String: Any] {
        guard let d = call.arguments.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private var summary: String {
        let a = args
        for key in ["tool_title", "label", "action", "task", "prompt", "command", "path", "url", "query", "content"] {
            if let s = a[key] as? String, !s.isEmpty {
                return s.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    private var prettyArgs: String {
        guard let d = call.arguments.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d),
              let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let s = String(data: p, encoding: .utf8) else { return call.arguments }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Image(systemName: icon)
                    Text(call.name).font(.callout.monospaced().bold())
                    Text(summary)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let r = result {
                        Image(systemName: r.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(r.isError ? Color.red : Color.green)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("参数").font(.caption).foregroundStyle(.secondary)
                    CodeBlock(code: prettyArgs, language: "json")
                    if let r = result {
                        Text("结果").font(.caption).foregroundStyle(.secondary)
                        CodeBlock(code: r.content.count > 20000 ? String(r.content.prefix(20000)) + "\n…" : r.content, language: "")
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if call.name == "memory_write", let c = args["content"] as? String {
                Button("撤销这条记忆") { _ = MemoryStore.revoke(c) }
            }
        }
    }
}

// MARK: - Approval

struct ApprovalBar: View {
    @EnvironmentObject var store: AppStore
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("请求执行以下命令", systemImage: "exclamationmark.shield")
                .font(.headline)
            ScrollView {
                Text(approval.command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("拒绝", role: .cancel) {
                    store.resolve(approval.id, allow: false)
                }
                Spacer()
                Button("始终允许") {
                    store.resolve(approval.id, allow: true, always: true)
                }
                .help("以后不再询问（可在设置中改回）")
                Button("允许") {
                    store.resolve(approval.id, allow: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1))
    }
}

// MARK: - Input

struct InputBar: View {
    @Binding var draft: String
    @Binding var images: [String]
    let running: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    ImageStrip(names: images, size: 56) { name in
                        images.removeAll { $0 == name }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: pickImages) {
                    Image(systemName: "paperclip").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("添加图片（也可以粘贴或拖入）")
                .padding(.bottom, 6)

                ZStack(alignment: .topLeading) {
                    ChatInputView(text: $draft, onSubmit: onSend, onPasteImages: { names in
                        images.append(contentsOf: names)
                    })
                    .frame(height: 64)
                    if draft.isEmpty {
                        Text("给 OpenMinis 发消息（Return 发送，Shift+Return 换行）")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))

                if running {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .help("停止")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("发送")
                }
            }
        }
        .padding(12)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        images.append(contentsOf: panel.urls.compactMap { Attachments.save(fileURL: $0) })
    }
}

/// NSTextView subclass that turns pasted images into attachments instead of rich text.
final class ChatTextView: NSTextView {
    var onPasteImages: (([String]) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let hasPlainText = pb.string(forType: .string) != nil
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if !hasPlainText || hasFiles {
            let names = Attachments.importImages(from: pb)
            if !names.isEmpty {
                onPasteImages?(names)
                return
            }
        }
        pasteAsPlainText(sender)
    }
}

/// Return sends, Shift/Option+Return inserts a newline,
/// and IME composition (e.g. Chinese pinyin) is never interrupted.
struct ChatInputView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onPasteImages: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let tv = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 64))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)

        tv.delegate = context.coordinator
        tv.onPasteImages = { names in context.coordinator.parent.onPasteImages(names) }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.string = text

        scroll.documentView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = scroll.documentView as? NSTextView, tv.string != text, !tv.hasMarkedText() {
            tv.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputView
        init(_ p: ChatInputView) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}


// MARK: - In-chat find bar (ChatSearchBar.swift)

struct FindBar: View {
    @Binding var query: String
    let label: String
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在对话中查找", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrev() } else { onNext() }
                }
                .onExitCommand(perform: onClose)
            Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(action: onPrev) { Image(systemName: "chevron.up") }.help("上一个（⇧⌘G / ⇧Return）")
            Button(action: onNext) { Image(systemName: "chevron.down") }.help("下一个（⌘G / Return）")
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.help("关闭（Esc）")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { focused = true }
    }
}
