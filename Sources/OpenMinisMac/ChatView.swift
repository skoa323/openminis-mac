import SwiftUI
import AppKit

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let conversationID: UUID
    @State private var draft = ""

    private var conversation: Conversation? { store.conversation(conversationID) }
    private var running: Bool { store.isRunning(conversationID) }

    var body: some View {
        let messages = conversation?.messages ?? []
        let results = Dictionary(
            messages.filter { $0.role == .tool }.compactMap { m in m.toolCallId.map { ($0, m) } },
            uniquingKeysWith: { _, b in b }
        )
        let visible = messages.filter { m in
            switch m.role {
            case .user: return true
            case .assistant: return !(m.content.isEmpty && m.toolCalls.isEmpty)
            default: return false
            }
        }
        let lastAssistantEmpty = messages.last.map { $0.role != .assistant || ($0.content.isEmpty && $0.toolCalls.isEmpty) } ?? true

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if visible.isEmpty {
                            EmptyChatHint()
                        }
                        ForEach(visible) { m in
                            MessageRow(message: m, results: results)
                                .id(m.id)
                        }
                        if running && (lastAssistantEmpty || store.approval(for: conversationID) == nil && messages.last?.role == .tool) {
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
                .onChange(of: messages.count) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: messages.last?.content.count ?? 0) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            if let a = store.approval(for: conversationID) {
                ApprovalBar(approval: a)
            }

            Divider()
            InputBar(draft: $draft, running: running, onSend: send, onStop: { store.stop(conversationID) })
        }
        .navigationTitle(conversation?.title ?? "OpenMinis")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        draft = ""
        store.send(text, in: conversationID)
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
            Text("我可以在这台 Mac 上运行命令、读写文件、抓取网页。\n直接告诉我要做什么。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - Messages

struct MessageRow: View {
    let message: ChatMessage
    let results: [String: ChatMessage]

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

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
        case "memory_write": return "brain"
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
        for key in ["command", "path", "url", "content"] {
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
    let running: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                ChatInputView(text: $draft, onSubmit: onSend)
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
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("发送")
            }
        }
        .padding(12)
    }
}

/// NSTextView wrapper: Return sends, Shift/Option+Return inserts a newline,
/// and IME composition (e.g. Chinese pinyin) is never interrupted.
struct ChatInputView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.delegate = context.coordinator
            tv.isRichText = false
            tv.allowsUndo = true
            tv.drawsBackground = false
            tv.font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
            tv.textContainerInset = NSSize(width: 0, height: 2)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.string = text
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
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
