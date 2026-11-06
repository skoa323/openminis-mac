import SwiftUI
import AppKit

/// Lightweight Markdown: fenced code blocks + inline styling via AttributedString.
struct MarkdownText: View {
    let text: String

    private enum Block: Identifiable {
        case text(Int, String)
        case code(Int, String, String)
        var id: Int {
            switch self {
            case .text(let i, _): return i
            case .code(let i, _, _): return i
            }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var buf: [String] = []
        var inCode = false
        var lang = ""
        func flush() {
            guard !buf.isEmpty else { return }
            let s = buf.joined(separator: "\n")
            if inCode {
                out.append(.code(out.count, lang, s))
            } else if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.text(out.count, s))
            }
            buf = []
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inCode {
                    flush()
                    inCode = false
                } else {
                    flush()
                    inCode = true
                    lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            buf.append(line)
        }
        flush() // unterminated fence while streaming still renders as code
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { b in
                switch b {
                case .text(_, let s):
                    Text(MarkdownText.inline(s))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let lang, let code):
                    CodeBlock(code: code, language: lang)
                }
            }
        }
    }

    static func inline(_ s: String) -> AttributedString {
        let lines = s.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let body = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return body.isEmpty ? "" : "**\(body)**"
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                let indent = String(line.prefix(while: { $0 == " " }))
                return indent + "• " + String(t.dropFirst(2))
            }
            return line
        }
        let joined = lines.joined(separator: "\n")
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: joined, options: opts)) ?? AttributedString(joined)
    }
}

struct CodeBlock: View {
    let code: String
    let language: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "text" : language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12))

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}
