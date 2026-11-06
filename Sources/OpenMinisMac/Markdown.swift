import SwiftUI
import AppKit

// MARK: - Block model (pure, unit-tested)

enum MDAlign: Equatable { case leading, center, trailing }

struct MDListItem: Equatable {
    var indent: Int        // nesting level, 0-based
    var marker: String     // "•", "1.", "☐", "☑"
    var text: String
}

enum MDBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String)               // language, code
    case quote([MDBlock])
    case list([MDListItem])
    case table([String], [MDAlign], [[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        parse(lines: text.components(separatedBy: "\n"))
    }

    static func parse(lines: [String]) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flushPara() {
            let s = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(.paragraph(s)) }
            para = []
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            // Fenced code (unterminated fence while streaming still renders as code)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushPara()
                let fence = String(t.prefix(3))
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                out.append(.code(lang, code.joined(separator: "\n")))
                continue
            }

            if t.isEmpty { flushPara(); i += 1; continue }

            // Heading
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                let rest = t.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.hasPrefix(" ") {
                    flushPara()
                    out.append(.heading(level, rest.trimmingCharacters(in: .whitespaces)))
                    i += 1; continue
                }
            }

            // Horizontal rule
            if isRule(t) { flushPara(); out.append(.rule); i += 1; continue }

            // Block quote
            if t.hasPrefix(">") {
                flushPara()
                var inner: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    var body = q.dropFirst()
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                    inner.append(String(body)); i += 1
                }
                out.append(.quote(parse(lines: inner)))
                continue
            }

            // Table: header row followed by a separator row
            if t.hasPrefix("|") || t.contains(" | "), i + 1 < lines.count,
               let aligns = separatorAligns(lines[i + 1]) {
                flushPara()
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty, r.contains("|") else { break }
                    rows.append(cells(r)); i += 1
                }
                let n = max(header.count, aligns.count)
                func pad(_ a: [String]) -> [String] {
                    a.count >= n ? Array(a.prefix(n)) : a + Array(repeating: "", count: n - a.count)
                }
                let al = aligns.count >= n ? Array(aligns.prefix(n)) : aligns + Array(repeating: .leading, count: n - aligns.count)
                out.append(.table(pad(header), al, rows.map(pad)))
                continue
            }

            // List
            if listItem(line) != nil {
                flushPara()
                var items: [MDListItem] = []
                while i < lines.count, let item = listItem(lines[i]) {
                    items.append(item); i += 1
                    // lazy continuation lines belong to the previous item
                    while i < lines.count {
                        let c = lines[i]
                        let ct = c.trimmingCharacters(in: .whitespaces)
                        guard !ct.isEmpty, listItem(c) == nil, c.hasPrefix("  ") else { break }
                        items[items.count - 1].text += " " + ct
                        i += 1
                    }
                }
                out.append(.list(items))
                continue
            }

            para.append(line)
            i += 1
        }
        flushPara()
        return out
    }

    static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    static func cells(_ row: String) -> [String] {
        var r = row.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") && !r.hasSuffix("\\|") { r.removeLast() }
        // split on unescaped pipes
        var cells: [String] = []
        var cur = ""
        var prev: Character = " "
        for ch in r {
            if ch == "|" && prev != "\\" { cells.append(cur); cur = "" }
            else if ch == "|" { cur.removeLast(); cur.append(ch) }
            else { cur.append(ch) }
            prev = ch
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func separatorAligns(_ line: String) -> [MDAlign]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return nil }
        let parts = cells(t)
        guard !parts.isEmpty else { return nil }
        var out: [MDAlign] = []
        for p in parts {
            let core = p.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            let l = p.hasPrefix(":"), r = p.hasSuffix(":")
            out.append(l && r ? .center : (r ? .trailing : .leading))
        }
        return out
    }

    static func listItem(_ line: String) -> MDListItem? {
        let spaces = line.prefix(while: { $0 == " " || $0 == "\t" })
        let width = spaces.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = line.dropFirst(spaces.count)
        let indent = width / 2

        for b in ["- ", "* ", "+ "] where t.hasPrefix(b) {
            var rest = String(t.dropFirst(2))
            var marker = "•"
            if rest.hasPrefix("[ ] ") { marker = "☐"; rest = String(rest.dropFirst(4)) }
            else if rest.lowercased().hasPrefix("[x] ") { marker = "☑"; rest = String(rest.dropFirst(4)) }
            return MDListItem(indent: indent, marker: marker, text: rest)
        }
        let digits = t.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let after = t.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return MDListItem(indent: indent, marker: String(digits) + ".", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

// MARK: - Rendering

struct MarkdownText: View {
    let text: String

    var body: some View {
        MarkdownBlocks(blocks: MarkdownParser.parse(text))
    }
}

struct MarkdownBlocks: View {
    let blocks: [MDBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                MarkdownBlockView(block: b)
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MDBlock

    var body: some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownParser.inline(s))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(MarkdownParser.inline(s))
                .font(Self.headingFont(level))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)
        case .code(let lang, let code):
            CodeBlock(code: code, language: lang)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                MarkdownBlocks(blocks: inner)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(it.marker)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(MarkdownParser.inline(it.text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(it.indent) * 18)
                }
            }
        case .table(let header, let aligns, let rows):
            MarkdownTable(header: header, aligns: aligns, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        default: return .headline
        }
    }
}

struct MarkdownTable: View {
    let header: [String]
    let aligns: [MDAlign]
    let rows: [[String]]

    private func alignment(_ i: Int) -> Alignment {
        switch i < aligns.count ? aligns[i] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in
                        cell(header[c], c).font(.body.bold())
                    }
                }
                .background(Color.secondary.opacity(0.12))
                ForEach(rows.indices, id: \.self) { r in
                    Divider()
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            cell(rows[r][c], c)
                        }
                    }
                    .background(r % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func cell(_ s: String, _ c: Int) -> some View {
        Text(MarkdownParser.inline(s))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 60, maxWidth: 360, alignment: alignment(c))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
                .accessibilityLabel("复制代码")
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
