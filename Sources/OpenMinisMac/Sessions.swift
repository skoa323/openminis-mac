import Foundation

// Port of upstream session management: ChatStore+Search, SidebarGrouping, SessionForkManager, ContentView+Export.
// Everything here is pure and unit-tested; AppStore+Sessions wires it to state.

// MARK: - Cross-session search (ChatStore+Search.swift)

struct SearchHit: Identifiable, Hashable {
    var id: UUID { conversationID }
    let conversationID: UUID
    let titleHit: Bool
    let snippet: String?
}

enum SessionSearch {
    /// Whitespace split (incl. full-width space), dedupe case-insensitively, max 10 terms.
    static func terms(_ query: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in query.split(whereSeparator: { $0.isWhitespace || $0 == "\u{3000}" }) {
            let t = String(raw)
            let k = t.lowercased()
            if t.isEmpty || seen.contains(k) { continue }
            seen.insert(k); out.append(t)
            if out.count == 10 { break }
        }
        return out
    }

    static func contains(_ s: String, _ term: String) -> Bool {
        s.range(of: term, options: [.caseInsensitive]) != nil
    }

    /// Line containing the first hit (terms in input order), windowed to `maxLength`
    /// with a fixed `lead` of context before the hit so late hits stay visible.
    static func hitLine(in text: String, terms: [String], maxLength: Int = 90, lead: Int = 18) -> String? {
        for term in terms {
            guard let r = text.range(of: term, options: .caseInsensitive) else { continue }
            let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if line.count <= maxLength {
                return line.trimmingCharacters(in: .whitespaces)
            }
            let hitOffset = line.distance(from: line.startIndex, to: r.lowerBound)
            let hitLen = text.distance(from: r.lowerBound, to: r.upperBound)
            let start = max(0, hitOffset - lead)
            let end = min(line.count, max(start + maxLength, hitOffset + hitLen))
            let si = line.index(line.startIndex, offsetBy: start)
            let ei = line.index(line.startIndex, offsetBy: end)
            var s = String(line[si..<ei]).trimmingCharacters(in: .whitespaces)
            if start > 0 { s = "…" + s }
            if end < line.count { s += "…" }
            return s
        }
        return nil
    }

    /// Text body first, then tool inputs (`🔧 name: line`), then tool results (`🔧 line`). Newest message first.
    static func snippet(_ c: Conversation, terms: [String]) -> String? {
        for m in c.messages.reversed() {
            switch m.role {
            case .user, .assistant:
                if let s = hitLine(in: m.content, terms: terms) { return s }
                for tc in m.toolCalls {
                    if let s = hitLine(in: tc.arguments, terms: terms) { return "🔧 \(tc.name): \(s)" }
                }
            case .tool:
                if let s = hitLine(in: m.content, terms: terms) { return "🔧 \(s)" }
            case .system:
                break
            }
        }
        return nil
    }

    /// OR across terms; keeps a conversation when the title matches or a snippet can be built.
    static func search(_ convs: [Conversation], query: String) -> [SearchHit] {
        let ts = terms(query)
        guard !ts.isEmpty else { return [] }
        return convs.filter { !$0.isChild }.sorted { $0.updatedAt > $1.updatedAt }.compactMap { c in
            let titleHit = ts.contains { contains(c.title, $0) }
            let snip = snippet(c, terms: ts)
            guard titleHit || snip != nil else { return nil }
            return SearchHit(conversationID: c.id, titleHit: titleHit, snippet: snip)
        }
    }

    /// Ranges of every term inside `s` (merged), for highlighting.
    static func hitRanges(in s: String, terms: [String]) -> [Range<String.Index>] {
        var rs: [Range<String.Index>] = []
        for t in terms where !t.isEmpty {
            var from = s.startIndex
            while from < s.endIndex, let r = s.range(of: t, options: .caseInsensitive, range: from..<s.endIndex) {
                rs.append(r); from = r.upperBound
            }
        }
        rs.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in rs {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }
}

// MARK: - In-chat find (ChatSearchEngine.swift)

struct FindMatch: Hashable { let messageID: UUID; let ordinal: Int }

enum ChatFind {
    static let perMessageCap = 200
    static let totalCap = 2000
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func count(_ q: String, in s: String) -> Int {
        guard !q.isEmpty else { return 0 }
        var n = 0
        var from = s.startIndex
        while n < perMessageCap, from < s.endIndex, let r = s.range(of: q, options: options, range: from..<s.endIndex) {
            n += 1; from = r.upperBound
        }
        return n
    }

    /// Whole query (no tokenizing), case- and diacritic-insensitive, over visible text.
    static func matches(_ messages: [ChatMessage], query: String) -> [FindMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [FindMatch] = []
        for m in messages where m.role != .system {
            var text = m.content
            if !m.reasoning.isEmpty { text += "\n" + m.reasoning }
            for tc in m.toolCalls { text += "\n" + tc.name + " " + tc.arguments }
            let n = count(q, in: text)
            for i in 0..<n {
                out.append(FindMatch(messageID: m.id, ordinal: i))
                if out.count >= totalCap { return out }
            }
        }
        return out
    }

    static func label(current: Int?, total: Int) -> String {
        let t = total >= totalCap ? "\(totalCap)+" : "\(total)"
        guard total > 0, let c = current else { return "0/\(t)" }
        return "\(c + 1)/\(t)"
    }
}

// MARK: - Sidebar grouping (ContentView+SidebarGrouping.swift)

enum DateBucket: Int, CaseIterable {
    case today, yesterday, week, month, earlier
    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "本周"
        case .month: return "本月"
        case .earlier: return "更早"
        }
    }

    static func of(_ d: Date, now: Date = Date(), calendar cal: Calendar = .current) -> DateBucket {
        if cal.isDate(d, inSameDayAs: now) { return .today }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return .yesterday }
        let start = cal.startOfDay(for: now)
        if let w = cal.date(byAdding: .day, value: -7, to: start), d >= w { return .week }
        if let m = cal.date(byAdding: .month, value: -1, to: start), d >= m { return .month }
        return .earlier
    }
}

enum SidebarSection: Hashable, Identifiable {
    case pinned, folder(UUID), bucket(DateBucket)
    var id: String {
        switch self {
        case .pinned: return "pinned"
        case .folder(let f): return "folder-" + f.uuidString
        case .bucket(let b): return "bucket-\(b.rawValue)"
        }
    }
}

enum SidebarGrouping {
    /// Pinned (unfiled) → folders (pinned folders first, then by latest activity; empty ones last)
    /// → date buckets for the rest. Inside a folder: pinned first, then by updatedAt.
    static func group(_ allConvs: [Conversation], folders: [ChatFolder], now: Date = Date())
        -> [(SidebarSection, [Conversation])] {
        let convs = allConvs.filter { !$0.isChild }
        let folderIDs = Set(folders.map(\.id))
        let filed = { (c: Conversation) -> Bool in c.folderID.map(folderIDs.contains) ?? false }
        var out: [(SidebarSection, [Conversation])] = []

        let pinned = convs.filter { $0.isPinned && !filed($0) }
            .sorted { ($0.updatedAt, $0.pinnedAt ?? .distantPast) > ($1.updatedAt, $1.pinnedAt ?? .distantPast) }
        if !pinned.isEmpty { out.append((.pinned, pinned)) }

        func lastActivity(_ f: ChatFolder) -> Date {
            convs.filter { $0.folderID == f.id }.map(\.updatedAt).max() ?? f.updatedAt
        }
        let sortedFolders = folders.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            let ae = !convs.contains { $0.folderID == a.id }
            let be = !convs.contains { $0.folderID == b.id }
            if ae != be { return !ae }
            return lastActivity(a) > lastActivity(b)
        }
        for f in sortedFolders {
            let members = convs.filter { $0.folderID == f.id }.sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                return a.updatedAt > b.updatedAt
            }
            out.append((.folder(f.id), members))
        }

        var buckets: [DateBucket: [Conversation]] = [:]
        for c in convs where !c.isPinned && !filed(c) {
            buckets[DateBucket.of(c.updatedAt, now: now), default: []].append(c)
        }
        for b in DateBucket.allCases {
            if let list = buckets[b], !list.isEmpty {
                out.append((.bucket(b), list.sorted { $0.updatedAt > $1.updatedAt }))
            }
        }
        return out
    }

    /// "刚刚" / "N 分钟前" / "N 小时前" / "昨天" / weekday / M/d.
    static func relative(_ d: Date, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if cal.isDate(d, inSameDayAs: now) { return "\(Int(s / 3600)) 小时前" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "昨天" }
        if s < 7 * 86400 {
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            return names[cal.component(.weekday, from: d) - 1]
        }
        let comps = cal.dateComponents([.month, .day], from: d)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)"
    }

    /// Second line of a row: last user/assistant text, single-lined.
    static func preview(_ c: Conversation) -> String {
        guard let m = c.messages.last(where: { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }) else {
            return "暂无消息"
        }
        return m.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Duplicate / fork (SessionForkManager.swift)

enum SessionCopy {
    static let copyWord = "副本"
    static let forkWord = "分叉"

    /// "Foo" → "Foo (副本)", then "Foo (副本 2)"… never "Foo (副本) (副本)".
    static func copyTitle(_ title: String, existing: [String], word: String = copyWord) -> String {
        var base = title.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "未命名" }
        if let r = base.range(of: #"\s\((副本|分叉)( \d+)?\)$"#, options: .regularExpression) {
            base = String(base[..<r.lowerBound])
        }
        let taken = Set(existing)
        var candidate = "\(base) (\(word))"
        var n = 2
        while taken.contains(candidate) { candidate = "\(base) (\(word) \(n))"; n += 1 }
        return candidate
    }

    /// Messages with fresh ids. Tool-call ids are kept so call/result pairs stay linked.
    static func cloneMessages(_ ms: [ChatMessage]) -> [ChatMessage] {
        ms.map { m in var c = m; c.id = UUID(); return c }
    }

    /// Prefix of the conversation through `messageID`; an assistant turn keeps its tool results.
    static func forkPrefix(_ ms: [ChatMessage], through messageID: UUID) -> [ChatMessage] {
        guard let i = ms.firstIndex(where: { $0.id == messageID }) else { return ms }
        var end = i
        if !ms[i].toolCalls.isEmpty {
            while end + 1 < ms.count, ms[end + 1].role == .tool { end += 1 }
        }
        return Array(ms[...end])
    }
}

// MARK: - Export (ContentView+Export.swift)

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, json, text
    var id: String { rawValue }
    var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .text: return "纯文本"
        }
    }
    var ext: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        case .text: return "txt"
        }
    }
}

enum SessionExport {
    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    static func fileName(_ convs: [Conversation], format: ExportFormat) -> String {
        if convs.count == 1 {
            var t = String(convs[0].title.prefix(60))
            for ch in ["/", ":"] { t = t.replacingOccurrences(of: ch, with: "-") }
            if t.trimmingCharacters(in: .whitespaces).isEmpty { t = "conversation" }
            return t + "." + format.ext
        }
        return "openminis-sessions-\(convs.count).\(format.ext)"
    }

    static func render(_ convs: [Conversation], format: ExportFormat) -> String {
        switch format {
        case .json: return json(convs)
        case .markdown: return convs.map(markdown).joined(separator: "\n\n---\n\n")
        case .text: return convs.map(text).joined(separator: "\n\n==========\n\n")
        }
    }

    static func json(_ convs: [Conversation]) -> String {
        let iso = ISO8601DateFormatter()
        let arr: [[String: Any]] = convs.map { c in
            let msgs: [[String: Any]] = c.messages.map { m in
                var d: [String: Any] = ["role": m.role.rawValue, "content": m.content, "date": iso.string(from: m.date)]
                if !m.reasoning.isEmpty { d["reasoning"] = m.reasoning }
                if !m.toolCalls.isEmpty {
                    d["tool_calls"] = m.toolCalls.map { ["id": $0.id, "name": $0.name, "arguments": $0.arguments] }
                }
                if let t = m.toolCallId { d["tool_call_id"] = t; d["success"] = !m.isError }
                if let n = m.toolName { d["tool_name"] = n }
                if !m.images.isEmpty { d["attachments"] = m.images.map { _ in ["type": "media", "note": "image attachment"] } }
                if let u = m.usage {
                    d["usage"] = ["input": u.input, "output": u.output, "cache_read": u.cacheRead,
                                  "cache_write": u.cacheWrite, "reasoning": u.reasoning]
                }
                if let l = m.modelLabel { d["model"] = l }
                if m.isError && m.role == .assistant { d["error"] = true }
                return d
            }
            return ["id": c.id.uuidString, "title": c.title, "created_at": iso.string(from: c.createdAt),
                    "updated_at": iso.string(from: c.updatedAt), "messages": msgs]
        }
        let obj: Any = convs.count == 1 ? arr[0] : arr
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    static func markdown(_ c: Conversation) -> String {
        var out = "# \(c.title)\n\n_\(stamp.string(from: c.createdAt))_\n"
        for m in c.messages {
            switch m.role {
            case .user:
                out += "\n## 用户 · \(stamp.string(from: m.date))\n\n\(m.content)\n"
                if !m.images.isEmpty { out += "\n_[\(m.images.count) 张图片附件]_\n" }
            case .assistant:
                if m.content.isEmpty && m.toolCalls.isEmpty && m.reasoning.isEmpty { continue }
                out += "\n## OpenMinis · \(stamp.string(from: m.date))\n"
                if !m.reasoning.isEmpty {
                    out += "\n<details><summary>思考过程</summary>\n\n" + m.reasoning + "\n\n</details>\n"
                }
                if !m.content.isEmpty { out += "\n\(m.content)\n" }
                for tc in m.toolCalls { out += "\n> 🔧 `\(tc.name)` \(tc.arguments)\n" }
            case .tool:
                let body = m.content.count > 2000 ? String(m.content.prefix(2000)) + "\n…" : m.content
                out += "\n<details><summary>结果\(m.isError ? "（失败）" : "")</summary>\n\n```\n\(body)\n```\n\n</details>\n"
            case .system:
                break
            }
        }
        return out
    }

    /// `[用户/OpenMinis] 时间\n正文\n---`, tools as `[Tool: name]` / `[Result: …]`.
    static func text(_ c: Conversation) -> String {
        var parts: [String] = ["\(c.title)"]
        for m in c.messages {
            switch m.role {
            case .user:
                var s = "[用户] \(stamp.string(from: m.date))\n\(m.content)"
                if !m.images.isEmpty { s += "\n[Attachment ×\(m.images.count)]" }
                parts.append(s + "\n---")
            case .assistant:
                if m.content.isEmpty && m.toolCalls.isEmpty { continue }
                var s = "[OpenMinis] \(stamp.string(from: m.date))\n\(m.content)"
                for tc in m.toolCalls { s += "\n[Tool: \(tc.name)]" }
                parts.append(s + "\n---")
            case .tool:
                let snap = m.content.prefix(200)
                parts.append("[Result: \(snap)\(m.content.count > 200 ? "…" : "")]")
            case .system:
                break
            }
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Titles

enum TitleGen {
    static func prompt(_ c: Conversation) -> String {
        var ctx = ""
        for m in c.messages where m.role == .user || (m.role == .assistant && !m.isError) {
            ctx += (m.role == .user ? "用户：" : "助手：") + m.content + "\n"
            if ctx.count > 2000 { break }
        }
        return "为下面这段对话起一个简短标题（不超过 15 个字，使用对话的语言，不要引号、标点结尾或解释），只输出标题：\n\n" + String(ctx.prefix(2000))
    }

    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.components(separatedBy: .newlines).first ?? s
        let junk = CharacterSet(charactersIn: "\"'“”‘’「」《》#*。.：: ")
        s = s.trimmingCharacters(in: junk)
        // Strip a "标题：" prefix, then trim again so quotes after it go too.
        if s.hasPrefix("标题") { s = String(s.dropFirst(2)).trimmingCharacters(in: junk) }
        return String(s.prefix(30))
    }
}
