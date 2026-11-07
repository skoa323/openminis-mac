import Foundation

// Pure (WebKit-free) part of browser_use: action enum, argument parsing, user-agent
// profiles and result formatting. Ported from upstream src/ios/Agent/BrowserUse/
// BrowserUseActions.swift + the static formatters of BrowserUseManager.swift (GPL-3.0).
// Everything here is nonisolated so ToolRunner and unit tests can use it off the main actor.

typealias BrowserInput = BrowserActionInput
typealias BrowserFormat = BrowserLogic

struct BrowserHistoryItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var timestamp: Date = Date()

    var domain: String {
        URL(string: url).flatMap(\.host) ?? url
    }
}

extension BrowserLogic {
    static var browserDir: URL {
        let d = AppStore.supportDir.appendingPathComponent("browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var offloadsDir: URL {
        let d = AppStore.supportDir.appendingPathComponent("offloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var downloadsDir: URL {
        let d = AppStore.supportDir.appendingPathComponent("browser/downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - Action

enum BrowserAction: String, CaseIterable {
    case navigate
    case screenshot
    case click
    case type
    case getText = "get_text"
    case scroll
    case getPageInfo = "get_page_info"
    case executeJS = "execute_js"
    case findElements = "find_elements"
    case hover
    case getReadable = "get_readable"
    case setUserAgent = "set_user_agent"
    case setViewport = "set_viewport"
    case getBackbone = "get_backbone"
    case fetch
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case listTabs = "list_tabs"
    case getCookies = "get_cookies"
    case setCookies = "set_cookies"
    case scrollAndCollect = "scroll_and_collect"
    case waitForDomStable = "wait_for_dom_stable"

    /// Actions that can change what is on screen; after them we wait for the DOM to
    /// settle and append a change summary (upstream `visualChangeActions`).
    static let visualChangeActions: Set<BrowserAction> = [.click, .type, .scroll, .hover]
}

// MARK: - Input

struct BrowserActionInput {
    enum ScrollDirection: String { case up, down }

    var action: BrowserAction
    var url: String? = nil
    var selector: String? = nil
    var text: String? = nil
    var coordinateX: Int? = nil
    var coordinateY: Int? = nil
    var direction: ScrollDirection? = nil
    var amount: Int? = nil
    var script: String? = nil
    var userAgent: UserAgentProfile? = nil
    var userAgentRaw: String? = nil
    var maxDepth: Int? = nil
    var tabId: Int? = nil
    var scrollCount: Int? = nil
    var itemSelector: String? = nil
    var keywords: [String]? = nil
    var fuzzy: Bool? = nil
    var timeout: Int? = nil
    var viewportWidth: Int? = nil
    var viewportHeight: Int? = nil
    var viewportReset: Bool? = nil
    var fullPage: Bool? = nil
    var cookies: [[String: Any]]? = nil

    enum ParseError: Error, Equatable {
        case invalidJSON
        case missingAction
        case unknownAction(String)

        var message: String {
            switch self {
            case .invalidJSON: return "browser_use: arguments are not a JSON object"
            case .missingAction: return "browser_use: missing 'action'. Valid actions: \(BrowserAction.allCases.map(\.rawValue).joined(separator: ", "))"
            case .unknownAction(let a): return "browser_use: unknown action \"\(a)\". Valid actions: \(BrowserAction.allCases.map(\.rawValue).joined(separator: ", "))"
            }
        }
    }

    static func parse(json: String) -> Result<BrowserActionInput, ParseError> {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        return parse(dict)
    }

    static func parse(_ dict: [String: Any]) -> Result<BrowserActionInput, ParseError> {
        guard let raw = dict["action"] as? String else { return .failure(.missingAction) }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let action = BrowserAction(rawValue: key) else { return .failure(.unknownAction(raw)) }
        var i = BrowserActionInput(action: action)
        i.url = nonEmpty(dict["url"])
        i.selector = nonEmpty(dict["selector"])
        i.text = dict["text"] as? String
        i.coordinateX = int(dict["coordinate_x"])
        i.coordinateY = int(dict["coordinate_y"])
        i.direction = (dict["direction"] as? String).flatMap { ScrollDirection(rawValue: $0.lowercased()) }
        i.amount = int(dict["amount"])
        i.script = dict["script"] as? String
        i.userAgentRaw = dict["user_agent"] as? String
        i.userAgent = UserAgentProfile.parse(i.userAgentRaw)
        i.maxDepth = int(dict["max_depth"])
        i.tabId = int(dict["tab_id"])
        i.scrollCount = int(dict["scroll_count"])
        i.itemSelector = nonEmpty(dict["item_selector"])
        i.keywords = parseKeywords(dict["keywords"] ?? dict["keyword"])
        i.fuzzy = bool(dict["fuzzy"])
        i.timeout = int(dict["timeout"])
        i.viewportWidth = int(dict["viewport_width"])
        i.viewportHeight = int(dict["viewport_height"])
        i.viewportReset = bool(dict["reset"])
        i.fullPage = bool(dict["full_page"])
        i.cookies = parseCookies(dict["cookies"])
        return .success(i)
    }

    // Loose scalar coercion: models send 3, 3.0 or "3" interchangeably.
    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber where !(n === kCFBooleanTrue || n === kCFBooleanFalse): return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces)) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func parseKeywords(_ raw: Any?) -> [String]? {
        var tokens: [String] = []
        if let arr = raw as? [Any] {
            tokens = arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if let s = raw as? String {
            tokens = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        }
        return tokens.isEmpty ? nil : tokens
    }

    /// `cookies` may be a real JSON array or a JSON-encoded string of one (the schema types it as string).
    static func parseCookies(_ raw: Any?) -> [[String: Any]]? {
        if let arr = raw as? [[String: Any]] { return arr }
        if let one = raw as? [String: Any] { return [one] }
        if let str = raw as? String {
            let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let d = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
            if let arr = obj as? [[String: Any]] { return arr }
            if let one = obj as? [String: Any] { return [one] }
        }
        return nil
    }
}

// MARK: - User agent

enum UserAgentProfile: String, CaseIterable, Codable, Identifiable {
    case desktopSafari = "desktop_safari"
    case mobileSafari = "mobile_safari"

    var id: String { rawValue }

    var userAgentString: String {
        switch self {
        case .desktopSafari:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case .mobileSafari:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
    }

    var label: String {
        switch self {
        case .desktopSafari: return "桌面版 Safari"
        case .mobileSafari: return "移动版 Safari（iPhone）"
        }
    }

    var icon: String { self == .desktopSafari ? "desktopcomputer" : "iphone" }

    /// Default layout size when the tab is not shown in the browser window.
    var viewportSize: (width: Int, height: Int) {
        switch self {
        case .desktopSafari: return (1280, 800)
        case .mobileSafari: return (390, 844)
        }
    }

    /// Accepts raw values plus `desktop` / `mobile`, case-insensitive, `-` == `_`. Unknown → nil.
    static func parse(_ raw: String?) -> UserAgentProfile? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch key {
        case "desktop": return .desktopSafari
        case "mobile": return .mobileSafari
        default: return UserAgentProfile(rawValue: key)
        }
    }

    static func invalidArgumentMessage(raw: String?) -> String {
        let got = raw.map { "\"\($0)\" is not a user agent profile" } ?? "user_agent is missing"
        return "set_user_agent: \(got). Use desktop_safari or mobile_safari (aliases: desktop, mobile). Nothing was changed."
    }
}

// MARK: - Result

struct BrowserActionResult {
    var text: String
    var success: Bool = true
    /// PNG written to disk (screenshot / post-action snapshot).
    var imageFilePath: String? = nil
    var tabId: Int? = nil
    var pageURL: String? = nil

    static func error(_ message: String) -> BrowserActionResult {
        BrowserActionResult(text: "Error: \(message)", success: false)
    }
}

// MARK: - Pure helpers

enum BrowserLogic {
    static let maxTabs = 6
    static let navigationTimeout: TimeInterval = 30
    static let readActionTimeout: TimeInterval = 15
    static let executeJSTimeout: TimeInterval = 45
    static let fullPageMaxHeight: Double = 32_768
    static let viewportRange = 200...4096

    // MARK: URLs

    enum URLCheck: Equatable {
        case ok(URL)
        case invalid(String)
    }

    /// Navigation targets from the agent: bare domains get https://, only http(s)/file/about allowed.
    static func normalizeNavigationURL(_ raw: String?) -> URLCheck {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .invalid("Missing 'url' parameter")
        }
        var s = raw
        if s.hasPrefix("/") || s.hasPrefix("~") {
            return .ok(URL(fileURLWithPath: (s as NSString).expandingTildeInPath))
        }
        if s == "about:blank" { return .ok(URL(string: s)!) }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else {
            return .invalid("Invalid URL: \(raw)")
        }
        guard ["http", "https", "file"].contains(scheme) else {
            return .invalid("Cannot navigate to \(scheme):// URLs. Only http://, https:// and file:// (or an absolute path) are supported.")
        }
        if scheme != "file", (url.host ?? "").isEmpty { return .invalid("Invalid URL: \(raw)") }
        return .ok(url)
    }

    /// Address-bar input from the user: URL if it looks like one, otherwise a web search.
    static func addressBarURL(_ input: String) -> URL? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("/") || t.hasPrefix("~") { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath) }
        if t.contains("://"), let u = URL(string: t) { return u }
        let looksLikeHost = !t.contains(" ") && (t.contains(".") || t.hasPrefix("localhost"))
        if looksLikeHost, let u = URL(string: "https://" + t), u.host != nil {
            if t.hasPrefix("localhost") { return URL(string: "http://" + t) }
            return u
        }
        var c = URLComponents(string: "https://www.bing.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url
    }

    static func stripHash(_ s: String) -> String {
        s.components(separatedBy: "#").first ?? s
    }

    // MARK: Viewport

    enum ViewportRequest: Equatable {
        case reset
        case set(width: Int, height: Int)
        case invalid(String)
    }

    static func viewportRequest(width: Int?, height: Int?, reset: Bool?) -> ViewportRequest {
        if reset == true { return .reset }
        guard let w = width, let h = height else {
            return .invalid("set_viewport requires viewport_width and viewport_height (or reset=true)")
        }
        guard viewportRange.contains(w), viewportRange.contains(h) else {
            return .invalid("set_viewport: width and height must be between \(viewportRange.lowerBound) and \(viewportRange.upperBound) CSS px (got \(w)x\(h))")
        }
        return .set(width: w, height: h)
    }

    // MARK: Cookies

    static func rootDomain(of host: String) -> String {
        let parts = host.split(separator: ".").map(String.init)
        if parts.count <= 2 || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    /// Cookie belongs to the current page host or its root domain.
    static func cookieMatchesHost(cookieDomain: String, host: String) -> Bool {
        let d = (cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain).lowercased()
        let h = host.lowercased()
        return d == h || d == rootDomain(of: h) || h.hasSuffix("." + d)
    }

    static func cookieNameMatches(_ name: String, keywords: [String]?, fuzzy: Bool) -> Bool {
        guard let keywords, !keywords.isEmpty else { return true }
        let n = name.lowercased()
        let kw = keywords.map { $0.lowercased() }
        return fuzzy ? kw.allSatisfy { n.contains($0) } : kw.contains(n)
    }

    static func cookieEnvName(_ name: String) -> String {
        var out = ""
        for ch in name.uppercased() {
            out.append(ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") ? ch : "_")
        }
        return "COOKIE_" + out
    }

    static func shellSingleQuote(_ v: String) -> String {
        "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Body of the env file written by get_cookies (values never go into the tool result).
    static func cookieEnvFile(_ cookies: [(name: String, value: String)]) -> String {
        var lines = ["#!/bin/sh"]
        var used = Set<String>()
        for c in cookies {
            var env = cookieEnvName(c.name)
            var n = 2
            while used.contains(env) { env = cookieEnvName(c.name) + "_\(n)"; n += 1 }
            used.insert(env)
            lines.append("export \(env)=\(shellSingleQuote(c.value))")
        }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        lines.append("export BROWSER_COOKIE_HEADER=\(shellSingleQuote(header))")
        return lines.joined(separator: "\n") + "\n"
    }

    static func cookieValue(_ dict: [String: Any], _ aliases: [String]) -> Any? {
        for k in aliases { if let v = dict[k] { return v } }
        let lowered = Set(aliases.map { $0.lowercased() })
        for (k, v) in dict where lowered.contains(k.lowercased()) { return v }
        return nil
    }

    static func cookieString(_ dict: [String: Any], _ aliases: [String]) -> String? {
        switch cookieValue(dict, aliases) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Builds HTTPCookie properties from one loosely-typed cookie object; nil when name/value missing.
    static func cookieProperties(_ raw: [String: Any], defaultDomain: String) -> [HTTPCookiePropertyKey: Any]? {
        guard let name = cookieString(raw, ["name"]), !name.isEmpty,
              let value = cookieString(raw, ["value"]) else { return nil }
        let domain = cookieString(raw, ["domain"]).flatMap { $0.isEmpty ? nil : $0 } ?? defaultDomain
        let path = cookieString(raw, ["path"]).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if BrowserActionInput.bool(cookieValue(raw, ["secure"])) == true { p[.secure] = "TRUE" }
        if BrowserActionInput.bool(cookieValue(raw, ["http_only", "httpOnly"])) == true {
            p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        let exp: Double? = {
            switch cookieValue(raw, ["expires", "expirationDate"]) {
            case let n as NSNumber: return n.doubleValue
            case let s as String: return Double(s)
            default: return nil
            }
        }()
        if let exp, exp > 0 { p[.expires] = Date(timeIntervalSince1970: exp) }
        if let ss = cookieString(raw, ["sameSite", "same_site"]), !ss.isEmpty {
            let v = ss.lowercased()
            if ["lax", "strict", "none"].contains(v) { p[.sameSitePolicy] = v }
        }
        return p
    }

    // MARK: Fetch

    static func parseContentDispositionFilename(_ cd: String) -> String? {
        guard !cd.isEmpty else { return nil }
        let patterns = ["filename\\*=(?:UTF-8''|utf-8'')([^;\\s]+)", "filename=\"([^\"]+)\"", "filename=([^;\\s]+)"]
        for pattern in patterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let m = re.firstMatch(in: cd, range: NSRange(cd.startIndex..., in: cd)),
               m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: cd) {
                let name = String(cd[r]).removingPercentEncoding ?? String(cd[r])
                if !name.isEmpty { return sanitizeFilename(name) }
            }
        }
        return nil
    }

    /// Strips path separators so a server-provided name cannot escape the downloads dir.
    static func sanitizeFilename(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 120 { s = String(s.suffix(120)) }
        return s.isEmpty ? "download" : s
    }

    static func extensionForMimeType(_ mime: String) -> String {
        let lower = mime.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        switch lower {
        case "text/html": return "html"
        case "text/plain": return "txt"
        case "text/css": return "css"
        case "text/csv": return "csv"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "application/zip": return "zip"
        case "application/gzip": return "gz"
        default: return "bin"
        }
    }

    static func fetchFilename(contentDisposition: String, finalURL: String, contentType: String, timestamp: Int) -> String {
        if let cd = parseContentDispositionFilename(contentDisposition) { return "\(timestamp)_\(cd)" }
        if let u = URL(string: finalURL), !u.lastPathComponent.isEmpty, u.lastPathComponent != "/" {
            return "\(timestamp)_\(sanitizeFilename(u.lastPathComponent))"
        }
        return "fetch_\(timestamp).\(extensionForMimeType(contentType))"
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func jsStringLiteral(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(e)\""
    }

    // MARK: JSON / result formatting

    static func parseJSONObject(_ raw: Any?) -> [String: Any]? {
        guard let s = raw as? String, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func int(_ v: Any?) -> Int {
        (v as? NSNumber)?.intValue ?? 0
    }

    /// Upstream `formatJSONResult`: human-readable lines for the built-in scripts' JSON.
    static func formatJSONResult(_ json: [String: Any]) -> String {
        var lines: [String] = []
        if json["clicked"] as? Bool == true {
            lines.append("Clicked <\(json["tag"] as? String ?? "?")>")
            if let x = json["x"], let y = json["y"] { lines.append("  Position: (\(x), \(y))") }
            if let t = json["text"] as? String, !t.isEmpty { lines.append("  Text: \(t.prefix(200))") }
        } else if json["typed"] as? Bool == true {
            lines.append("Typed \(int(json["length"])) chars into \(json["selector"] as? String ?? "?")")
        } else if json["scrolled"] as? Bool == true {
            lines.append("Scrolled \(json["direction"] as? String ?? "?") \(int(json["amount"]))px")
            if let y = json["scrollY"] { lines.append("  Scroll Y: \(y)") }
            if let h = json["scrollHeight"] { lines.append("  Page height: \(h)") }
            if let vh = json["viewportHeight"] { lines.append("  Viewport height: \(vh)") }
        } else if let sel = json["scrolledTo"] as? String {
            lines.append("Scrolled to <\(json["tag"] as? String ?? "?")> (\(sel))")
        } else if json["hovered"] as? Bool == true {
            lines.append("Hovered <\(json["tag"] as? String ?? "?")>")
            if let t = json["text"] as? String, !t.isEmpty { lines.append("  Text: \(t.prefix(200))") }
        } else if let text = json["text"] as? String, json["length"] != nil {
            if let title = json["title"] as? String, !title.isEmpty { lines.append("Title: \(title)") }
            let len = (json["length"] as? NSNumber)?.intValue ?? text.count
            lines.append("Text (\(len) chars):")
            lines.append(String(text.prefix(10000)))
        } else if let elements = json["elements"] as? [[String: Any]], json["count"] != nil {
            let count = int(json["count"])
            let shown = (json["shown"] as? NSNumber)?.intValue ?? elements.count
            lines.append("Found \(count) element(s) (showing \(shown)):")
            for el in elements {
                var d = "  [\(int(el["index"]))] <\(el["tag"] as? String ?? "?")>"
                if let id = el["id"] as? String, !id.isEmpty { d += " #\(id)" }
                let t = (el["text"] as? String ?? "").prefix(80)
                if !t.isEmpty { d += " \"\(t)\"" }
                if let href = el["href"] as? String, !href.isEmpty { d += " → \(href)" }
                lines.append(d)
            }
        } else {
            for (k, v) in json.sorted(by: { $0.key < $1.key }) { lines.append("  \(k): \(v)") }
        }
        return lines.joined(separator: "\n")
    }

    static func formatScrollAndCollectResult(_ json: [String: Any]) -> String {
        var lines: [String] = []
        lines.append("Collected \(int(json["itemsCollected"])) unique items (\(int(json["totalItemsSeen"])) total seen) over \(int(json["scrollSteps"])) scroll steps")
        lines.append("  Item selector: \(json["itemSelector"] as? String ?? "?")")
        lines.append("  Final scroll position: \(int(json["scrollPosition"]))")
        lines.append("")
        if let items = json["items"] as? [String] {
            for (i, item) in items.enumerated() {
                let compact = item.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                lines.append("[\(i + 1)] \(compact)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static let maxBackboneDepth = 64

    static func formatBackboneResult(_ json: [String: Any]) -> String {
        var lines = ["Page backbone: \(int(json["nodeCount"])) nodes, depth \(int(json["depth"])), \(int(json["merged"])) merged"]
        if let nodes = json["backbone"] as? [[String: Any]] {
            for n in nodes { formatBackboneNode(n, indent: 0, lines: &lines) }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatBackboneNode(_ node: [String: Any], indent: Int, lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        if indent > maxBackboneDepth {
            lines.append(pad + "[truncated: nesting deeper than \(maxBackboneDepth) levels]")
            return
        }
        var header = "\(pad)<\(node["tag"] as? String ?? "?")>"
        if let id = node["id"] as? String, !id.isEmpty { header += " #\(id)" }
        if let cls = node["cls"] as? String, !cls.isEmpty { header += " .\(cls.replacingOccurrences(of: " ", with: "."))" }
        if let role = node["role"] as? String { header += " [\(role)]" }
        header += " | \(node["sel"] as? String ?? "") | \(node["rect"] as? String ?? "")"
        lines.append(header)
        if let t = node["text"] as? String, !t.isEmpty { lines.append("\(pad)  \"\(t)\"") }
        if let h = node["href"] as? String, !h.isEmpty { lines.append("\(pad)  → \(h)") }
        if let i = node["img"] as? String, !i.isEmpty { lines.append("\(pad)  img: \(i)") }
        if let i = node["input"] as? String, !i.isEmpty { lines.append("\(pad)  input: \(i)") }
        if let kids = node["children"] as? [[String: Any]] {
            for k in kids { formatBackboneNode(k, indent: indent + 1, lines: &lines) }
        }
    }

    /// DOM change summary appended after click/type/scroll/hover (upstream collectDomChangeSummary).
    static func formatDomSummary(_ info: [String: Any]) -> String {
        let mutations = int(info["mutations"])
        if mutations == 0 { return "DOM: no changes detected" }
        var parts: [String] = []
        if info["urlChanged"] as? Bool == true, let u = info["urlNow"] as? String { parts.append("navigated to \(u)") }
        if let tags = info["addedTags"] as? [String: Any], !tags.isEmpty {
            let sorted = tags.map { ($0.key, int($0.value)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(5)
            parts.append("added: " + sorted.map { "\($0.1) \($0.0)" }.joined(separator: ", "))
        }
        let removed = int(info["removedCount"])
        if removed > 0 { parts.append("\(removed) nodes removed") }
        let attr = int(info["attrChanges"]), text = int(info["textChanges"])
        if attr > 0 || text > 0 {
            var c: [String] = []
            if attr > 0 { c.append("\(attr) attr") }
            if text > 0 { c.append("\(text) text") }
            parts.append(c.joined(separator: "+") + " updates")
        }
        if let nt = info["newTexts"] as? [String], !nt.isEmpty { parts.append("new content: " + nt.prefix(3).joined(separator: " | ")) }
        if let t = info["titleNow"] as? String, !t.isEmpty { parts.append("title: \(t)") }
        return "DOM: \(mutations) mutations — \(parts.joined(separator: "; "))"
    }

    // MARK: DOM stability (wait_for_dom_stable)

    enum StabilityStep: Equatable { case keepWaiting, settled }

    /// Gradient rule: per-interval mutation count non-increasing for `needed` consecutive polls.
    struct StabilityTracker {
        var needed = 3
        private(set) var previous = Int.max
        private(set) var stableRuns = 0
        private(set) var samples: [Int] = []

        init(needed: Int = 3) { self.needed = needed }

        mutating func add(_ count: Int) -> StabilityStep {
            samples.append(count)
            stableRuns = count <= previous ? stableRuns + 1 : 0
            previous = count
            return stableRuns >= needed ? .settled : .keepWaiting
        }

        var total: Int { samples.reduce(0, +) }
        var last: Int { samples.last ?? 0 }
    }

    // MARK: execute_js return value

    /// Upstream wrapExecuteJSReturn: normalizes DOMRect/Node/etc. in-page before IPC.
    static func wrapExecuteJSReturn(_ script: String) -> String {
        """
        const __minisNormalize = (function () {
            const MAX_DEPTH = 32;
            function norm(v, depth, seen) {
                if (v === null || v === undefined) return null;
                const t = typeof v;
                if (t === 'number') return isFinite(v) ? v : String(v);
                if (t === 'string' || t === 'boolean') return v;
                if (t === 'bigint') return String(v);
                if (t === 'function' || t === 'symbol') return undefined;
                if (depth >= MAX_DEPTH) return '[max depth]';
                if (seen.has(v)) return '[circular]';
                seen.add(v);
                try {
                    if (Array.isArray(v)) {
                        const out = [];
                        for (let i = 0; i < v.length; i++) out.push(norm(v[i], depth + 1, seen));
                        return out;
                    }
                    if (typeof v.toJSON === 'function') {
                        return norm(v.toJSON(), depth + 1, seen);
                    }
                    if (v instanceof Error) {
                        return { name: v.name, message: v.message, stack: String(v.stack || '') };
                    }
                    if (typeof Node !== 'undefined' && v instanceof Node) {
                        return { nodeName: v.nodeName, id: v.id || null,
                                 text: String(v.textContent || '').substring(0, 200) };
                    }
                    if (typeof v[Symbol.iterator] === 'function' && !(v instanceof String)) {
                        const out = [];
                        for (const item of v) {
                            out.push(norm(item, depth + 1, seen));
                            if (out.length >= 1000) break;
                        }
                        return out;
                    }
                    const out = {};
                    for (const k in v) {
                        const got = norm(v[k], depth + 1, seen);
                        if (got !== undefined) out[k] = got;
                    }
                    return out;
                } finally {
                    seen.delete(v);
                }
            }
            return function (v) {
                try { return norm(v, 0, new WeakSet()); } catch (e) { return v; }
            };
        })();
        const __minisResult = await (async () => {
        \(script)
        })();
        return __minisNormalize(__minisResult);
        """
    }

    static let maxSanitizeDepth = 64

    /// Serializes a JS return value: strings verbatim, everything else as JSON (NaN/Inf → null).
    static func stringifyJSReturn(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let s = value as? String { return s }
        let clean = sanitizeForJSON(value)
        if let d = try? JSONSerialization.data(withJSONObject: clean, options: [.fragmentsAllowed, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) { return s }
        return String(describing: value)
    }

    static func sanitizeForJSON(_ value: Any, depth: Int = 0) -> Any {
        if depth > maxSanitizeDepth { return "[truncated: nesting deeper than \(maxSanitizeDepth) levels]" }
        if let d = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = sanitizeForJSON(v, depth: depth + 1) }
            return out
        }
        if let a = value as? [Any] { return a.map { sanitizeForJSON($0, depth: depth + 1) } }
        if let n = value as? NSNumber {
            let t = CFNumberGetType(n as CFNumber)
            if t == .float32Type || t == .float64Type || t == .cgFloatType || t == .doubleType || t == .floatType,
               !n.doubleValue.isFinite { return NSNull() }
            return n
        }
        if value is String || value is NSNull { return value }
        return String(describing: value)
    }

    // MARK: Metadata lines

    static func pageMetadataLines(header: String, url: String, title: String, viewport: (Int, Int),
                                  pageSize: (Int, Int), scroll: (Int, Int)) -> [String] {
        var lines = [header]
        if !url.isEmpty { lines.append("  URL: \(url)") }
        if !title.isEmpty { lines.append("  Title: \(title)") }
        lines.append("  Viewport: \(viewport.0)x\(viewport.1)")
        if pageSize.0 > 0 || pageSize.1 > 0 { lines.append("  Page size: \(pageSize.0)x\(pageSize.1)") }
        lines.append("  Scroll position: (\(scroll.0), \(scroll.1))")
        return lines
    }

    /// Final text handed to the model: tab tag, then body, then any intercepted dialogs.
    static func toolOutput(_ r: BrowserActionResult, dialogs: [String] = []) -> String {
        var s = r.text
        if let t = r.tabId { s = "[tab_id: \(t)] " + s }
        if !dialogs.isEmpty {
            s += "\n\n[JavaScript dialogs auto-answered]\n" + dialogs.map { "  " + $0 }.joined(separator: "\n")
        }
        return s
    }

    static func listTabsText(_ tabs: [(id: Int, title: String, url: String)], selected: Int?) -> String {
        guard !tabs.isEmpty else { return "No tabs open. Use navigate (opens one automatically) or new_tab." }
        var lines = ["Open tabs (\(tabs.count)/\(maxTabs)):"]
        for t in tabs {
            let title = t.title.isEmpty ? "(untitled)" : t.title
            let url = t.url.isEmpty ? "(blank)" : t.url
            lines.append("  Tab \(t.id): \(title) — \(url)\(t.id == selected ? " *" : "")")
        }
        return lines.joined(separator: "\n")
    }
}
