import Foundation
import AppKit
import WebKit

/// One browser tab plus its WKWebView and navigation/UI delegates.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: Int
    @Published var webView: WKWebView
    @Published var title: String = ""
    @Published var currentURL: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var profile: UserAgentProfile
    @Published var viewport: (width: Int, height: Int)
    @Published var lastError: String? = nil

    var navigationContinuation: CheckedContinuation<Void, Error>?
    private(set) var interceptedDialogs: [String] = []
    private static let maxDialogs = 20

    var onRecordHistory: ((String, String) -> Void)?
    var onCreatePopupTab: ((WKWebViewConfiguration, URL?) -> WKWebView?)?
    var onCloseTab: ((Int) -> Void)?

    init(id: Int, profile: UserAgentProfile, viewport: (width: Int, height: Int)? = nil,
         configuration: WKWebViewConfiguration? = nil) {
        self.id = id
        self.profile = profile
        let vp = viewport ?? profile.viewportSize
        self.viewport = vp
        let wv = Self.buildWebView(profile: profile, viewport: vp, existingConfig: configuration)
        self.webView = wv
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
    }

    static let sharedProcessPool = WKProcessPool()

    static func buildWebView(profile: UserAgentProfile,
                             viewport: (width: Int, height: Int),
                             existingConfig: WKWebViewConfiguration? = nil) -> WKWebView {
        let config = existingConfig ?? WKWebViewConfiguration()
        if existingConfig == nil {
            config.processPool = sharedProcessPool
            config.websiteDataStore = .default()
        }
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.removeAllUserScripts()
        config.userContentController.addUserScript(viewportScript(width: viewport.width))
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height),
                           configuration: config)
        wv.customUserAgent = profile.userAgentString
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }

    private static func viewportScript(width: Int) -> WKUserScript {
        let js = """
        (function() {
            var w = \(width);
            function apply() {
                var metas = document.querySelectorAll('meta[name="viewport"]');
                metas.forEach(function(m) { if (m.parentNode) m.parentNode.removeChild(m); });
                var m = document.createElement('meta');
                m.name = 'viewport';
                m.content = 'width=' + w + ', initial-scale=1.0, user-scalable=yes';
                (document.head || document.documentElement).appendChild(m);
            }
            apply();
            document.addEventListener('DOMContentLoaded', apply);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    func rebuildWebView(profile: UserAgentProfile, viewport: (width: Int, height: Int)) {
        self.profile = profile
        self.viewport = viewport
        let oldURL = webView.url
        let wv = Self.buildWebView(profile: profile, viewport: viewport)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        self.webView = wv
        if let u = oldURL { wv.load(URLRequest(url: u)) }
    }

    func syncState() {
        currentURL = webView.url?.absoluteString ?? currentURL
        title = webView.title ?? title
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func drainDialogs() -> [String] {
        let out = interceptedDialogs
        interceptedDialogs.removeAll()
        return out
    }

    private func recordDialog(_ entry: String) {
        if interceptedDialogs.count >= Self.maxDialogs { interceptedDialogs.removeFirst() }
        interceptedDialogs.append(entry)
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = true
            self.lastError = nil
            self.syncState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in self.syncState() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.lastError = nil
            self.syncState()
            if !self.currentURL.isEmpty, self.currentURL != "about:blank" {
                self.onRecordHistory?(self.currentURL, self.title)
            }
            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
            self.lastError = error.localizedDescription
            self.syncState()
            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume(throwing: error)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
            self.lastError = error.localizedDescription
            self.syncState()
            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume(throwing: error)
            }
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.isLoading = false
            let err = NSError(domain: "BrowserUse", code: -3001,
                              userInfo: [NSLocalizedDescriptionKey: "WebContent process terminated"])
            self.lastError = err.localizedDescription
            if let cont = self.navigationContinuation {
                self.navigationContinuation = nil
                cont.resume(throwing: err)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed: Set<String> = ["http", "https", "file", "about", "blob", "data"]
        if let scheme = navigationAction.request.url?.scheme?.lowercased(), !allowed.contains(scheme) {
            decisionHandler(.cancel)
            Task { @MainActor in
                self.isLoading = false
                if let cont = self.navigationContinuation {
                    self.navigationContinuation = nil
                    cont.resume(throwing: URLError(.unsupportedURL))
                }
            }
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    @MainActor
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let wv = onCreatePopupTab?(configuration, navigationAction.request.url) { return wv }
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    nonisolated func webViewDidClose(_ webView: WKWebView) {
        Task { @MainActor in self.onCloseTab?(self.id) }
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
        Task { @MainActor in self.recordDialog("alert(\"\(message)\") -> dismissed") }
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
        Task { @MainActor in self.recordDialog("confirm(\"\(message)\") -> false") }
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptTextInputPanelWithPrompt prompt: String,
                             defaultText: String?,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
        Task { @MainActor in self.recordDialog("prompt(\"\(prompt)\") -> null") }
    }
}

// MARK: - BrowserManager

@MainActor
final class BrowserManager: ObservableObject {
    static let shared = BrowserManager()

    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedTabId: Int? = nil
    @Published var history: [BrowserHistoryItem] = []
    @Published var defaultProfile: UserAgentProfile {
        didSet {
            UserDefaults.standard.set(defaultProfile.rawValue, forKey: Self.uaDefaultsKey)
        }
    }
    /// Session-level custom viewport set by `set_viewport`; nil means use each tab's UA default.
    @Published private(set) var sessionViewport: (width: Int, height: Int)? = nil

    private var nextTabId: Int = 0
    private static let uaDefaultsKey = "OpenMinisMac.browserDefaultUA"
    private static var historyFileURL: URL {
        AppStore.supportDir.appendingPathComponent("browser_history.json")
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.uaDefaultsKey)
        self.defaultProfile = UserAgentProfile.parse(saved) ?? .desktopSafari
        loadHistory()
    }

    var activeTab: BrowserTab? {
        if let id = selectedTabId, let t = tabs.first(where: { $0.id == id }) { return t }
        return tabs.first
    }

    var currentTitle: String { activeTab?.title ?? "" }
    var currentURL: String { activeTab?.currentURL ?? "" }
    var canGoBack: Bool { activeTab?.canGoBack ?? false }
    var canGoForward: Bool { activeTab?.canGoForward ?? false }
    var isLoading: Bool { activeTab?.isLoading ?? false }

    func effectiveViewport(for profile: UserAgentProfile) -> (width: Int, height: Int) {
        sessionViewport ?? profile.viewportSize
    }

    // MARK: - History & Data Management

    func recordHistory(url: String, title: String) {
        guard !url.isEmpty, url != "about:blank" else { return }
        if let first = history.first, first.url == url { return }
        let item = BrowserHistoryItem(url: url, title: title, timestamp: Date())
        history.insert(item, at: 0)
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        history.removeAll { $0.timestamp < cutoff }
        if history.count > 500 { history = Array(history.prefix(500)) }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func loadHistory() {
        guard let d = try? Data(contentsOf: Self.historyFileURL),
              let items = try? JSONDecoder().decode([BrowserHistoryItem].self, from: d) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        history = items.filter { $0.timestamp >= cutoff }
    }

    private func saveHistory() {
        guard let d = try? JSONEncoder().encode(history) else { return }
        try? d.write(to: Self.historyFileURL, options: .atomic)
    }

    func clearCookiesAndData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                cont.resume()
            }
        }
    }

    func allCookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
    }

    // MARK: - User UI Navigation

    @discardableResult
    func createTabForUI(url: String? = nil) -> BrowserTab {
        if let tab = makeTab(configuration: nil) {
            if let url, let u = BrowserFormat.addressBarURL(url) {
                load(url: u, on: tab)
            }
            return tab
        }
        let fallback = activeTab ?? tabs[0]
        if let url, let u = BrowserFormat.addressBarURL(url) {
            load(url: u, on: fallback)
        }
        return fallback
    }

    func selectTab(_ id: Int) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabId = id
        objectWillChange.send()
    }

    func closeTabForUI(_ id: Int) {
        _ = closeTabAction(id: id)
    }

    func loadAddressBar(_ input: String) {
        guard let u = BrowserFormat.addressBarURL(input) else { return }
        let tab = activeTab ?? createTabForUI()
        load(url: u, on: tab)
    }

    func goBack() { activeTab?.webView.goBack() }
    func goForward() { activeTab?.webView.goForward() }
    func reload() { activeTab?.webView.reload() }
    func stopLoading() {
        activeTab?.webView.stopLoading()
        activeTab?.isLoading = false
    }

    private func load(url: URL, on tab: BrowserTab) {
        tab.lastError = nil
        tab.isLoading = true
        if url.isFileURL {
            tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            tab.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                        timeoutInterval: BrowserFormat.navigationTimeout))
        }
        objectWillChange.send()
    }

    private func makeTab(configuration: WKWebViewConfiguration?) -> BrowserTab? {
        guard tabs.count < BrowserFormat.maxTabs else { return nil }
        let id = nextTabId
        nextTabId += 1
        let vp = effectiveViewport(for: defaultProfile)
        let tab = BrowserTab(id: id, profile: defaultProfile, viewport: vp, configuration: configuration)
        tab.onRecordHistory = { [weak self] url, title in
            self?.recordHistory(url: url, title: title)
            self?.objectWillChange.send()
        }
        tab.onCreatePopupTab = { [weak self] config, url in
            guard let self, let popup = self.makeTab(configuration: config) else { return nil }
            if let url { self.load(url: url, on: popup) }
            return popup.webView
        }
        tab.onCloseTab = { [weak self] tid in
            _ = self?.closeTabAction(id: tid)
        }
        tabs.append(tab)
        selectedTabId = id
        objectWillChange.send()
        return tab
    }

    // MARK: - Tool Runner Entry

    func runTool(_ args: [String: Any]) async -> ToolResult {
        switch BrowserInput.parse(args) {
        case .failure(let err):
            return ToolResult(output: err.message, isError: true)
        case .success(let input):
            let res = await execute(input)
            let dialogs = res.tabId.flatMap { tid in tabs.first(where: { $0.id == tid })?.drainDialogs() } ?? []
            let out = BrowserFormat.toolOutput(res, dialogs: dialogs)
            return ToolResult(output: out, isError: !res.success)
        }
    }

    // MARK: - Execute BrowserInput

    func execute(_ input: BrowserInput) async -> BrowserActionResult {
        switch input.action {
        case .newTab:
            return await newTabAction(url: input.url)
        case .closeTab:
            let tid = input.tabId ?? selectedTabId ?? tabs.first?.id
            guard let tid else { return .error("No tabs are open.") }
            return closeTabAction(id: tid)
        case .listTabs:
            let list = tabs.map { (id: $0.id, title: $0.title, url: $0.currentURL) }
            return BrowserActionResult(text: BrowserFormat.listTabsText(list, selected: selectedTabId),
                                       tabId: selectedTabId)
        case .setViewport:
            return setViewportAction(width: input.viewportWidth, height: input.viewportHeight, reset: input.viewportReset)
        default:
            break
        }

        if input.action == .setUserAgent, input.userAgent == nil {
            return .error(UserAgentProfile.invalidArgumentMessage(raw: input.userAgentRaw))
        }

        // Resolve target tab
        let tab: BrowserTab
        if let requested = input.tabId {
            if tabs.isEmpty && requested == 0 {
                guard let created = makeTab(configuration: nil) else {
                    return .error("Maximum tabs (\(BrowserFormat.maxTabs)) reached.")
                }
                tab = created
            } else if let found = tabs.first(where: { $0.id == requested }) {
                tab = found
                selectedTabId = found.id
            } else {
                return .error("No tab with id \(requested). Use list_tabs to see open tabs.")
            }
        } else if let active = activeTab {
            tab = active
        } else {
            guard let created = makeTab(configuration: nil) else {
                return .error("Maximum tabs (\(BrowserFormat.maxTabs)) reached.")
            }
            tab = created
        }

        var result = await executeOnTab(input, tab: tab)
        if result.tabId == nil { result.tabId = tab.id }
        if result.pageURL == nil, !tab.currentURL.isEmpty { result.pageURL = tab.currentURL }
        objectWillChange.send()
        return result
    }

    // MARK: - Tab & Viewport Actions

    private func newTabAction(url: String?) async -> BrowserActionResult {
        guard let tab = makeTab(configuration: nil) else {
            return .error("Maximum tabs (\(BrowserFormat.maxTabs)) reached. Close an existing tab first.")
        }
        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let navRes = await navigateAction(url: url, on: tab)
            if !navRes.success { return navRes }
            return BrowserActionResult(text: "Opened new tab \(tab.id) and navigated.\n" + navRes.text,
                                       success: true, imageFilePath: navRes.imageFilePath,
                                       tabId: tab.id, pageURL: tab.currentURL)
        }
        return BrowserActionResult(text: "Opened new tab \(tab.id) (\( tabs.count)/\(BrowserFormat.maxTabs))",
                                   tabId: tab.id)
    }

    private func closeTabAction(id: Int) -> BrowserActionResult {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else {
            return .error("No tab with id \(id). Use list_tabs to see open tabs.")
        }
        let removed = tabs.remove(at: idx)
        removed.webView.stopLoading()
        if selectedTabId == id {
            selectedTabId = tabs.last?.id
        }
        objectWillChange.send()
        return BrowserActionResult(text: "Closed tab \(id) (\(tabs.count)/\(BrowserFormat.maxTabs) remaining)",
                                   tabId: selectedTabId)
    }

    private func setViewportAction(width: Int?, height: Int?, reset: Bool?) -> BrowserActionResult {
        switch BrowserFormat.viewportRequest(width: width, height: height, reset: reset) {
        case .invalid(let msg):
            return .error(msg)
        case .reset:
            sessionViewport = nil
            for t in tabs {
                let vp = t.profile.viewportSize
                t.rebuildWebView(profile: t.profile, viewport: vp)
            }
            let def = defaultProfile.viewportSize
            objectWillChange.send()
            return BrowserActionResult(text: "Viewport reset to default (\(def.width)x\(def.height))",
                                       tabId: selectedTabId)
        case .set(let w, let h):
            sessionViewport = (w, h)
            for t in tabs {
                t.rebuildWebView(profile: t.profile, viewport: (w, h))
            }
            objectWillChange.send()
            return BrowserActionResult(text: "Viewport set to \(w)x\(h) for this session",
                                       tabId: selectedTabId)
        }
    }

    // MARK: - Per-Tab Action Dispatch

    private func executeOnTab(_ input: BrowserInput, tab: BrowserTab) async -> BrowserActionResult {
        let prevURL = tab.webView.url?.absoluteString ?? tab.currentURL
        var result: BrowserActionResult

        switch input.action {
        case .navigate:
            result = await navigateAction(url: input.url, on: tab)
        case .screenshot:
            return await screenshotAction(fullPage: input.fullPage ?? false, on: tab)
        case .click:
            result = await clickAction(selector: input.selector, x: input.coordinateX, y: input.coordinateY, on: tab)
        case .type:
            result = await typeAction(selector: input.selector, text: input.text, on: tab)
        case .getText:
            return await evaluateReadJS(BrowserUseJS.getText(selector: input.selector), on: tab)
        case .getReadable:
            return await evaluateReadJS(BrowserUseJS.getReadable(), on: tab)
        case .getPageInfo:
            return await evaluateReadJS(BrowserUseJS.getPageInfo(), on: tab)
        case .findElements:
            guard let sel = input.selector else { return .error("find_elements requires 'selector'") }
            return await evaluateReadJS(BrowserUseJS.findElements(selector: sel), on: tab)
        case .hover:
            guard let sel = input.selector else { return .error("hover requires 'selector'") }
            result = await evaluateReadJS(BrowserUseJS.hover(selector: sel), on: tab)
        case .getBackbone:
            return await getBackboneAction(maxDepth: input.maxDepth, on: tab)
        case .scroll:
            result = await scrollAction(selector: input.selector, direction: input.direction, amount: input.amount, on: tab)
        case .scrollAndCollect:
            return await scrollAndCollectAction(selector: input.selector, direction: input.direction,
                                                amount: input.amount, scrollCount: input.scrollCount,
                                                itemSelector: input.itemSelector, on: tab)
        case .executeJS:
            return await executeJSAction(script: input.script, on: tab)
        case .waitForDomStable:
            return await waitForDomStableAction(timeout: input.timeout, on: tab)
        case .setUserAgent:
            guard let profile = input.userAgent else {
                return .error(UserAgentProfile.invalidArgumentMessage(raw: input.userAgentRaw))
            }
            let vp = sessionViewport ?? profile.viewportSize
            tab.rebuildWebView(profile: profile, viewport: vp)
            return BrowserActionResult(text: "Switched to \(profile.rawValue) (\(vp.width)x\(vp.height))",
                                       tabId: tab.id, pageURL: tab.currentURL)
        case .getCookies:
            return await getCookiesAction(keywords: input.keywords, fuzzy: input.fuzzy ?? true, on: tab)
        case .setCookies:
            return await setCookiesAction(cookies: input.cookies, on: tab)
        case .fetch:
            return await fetchAction(url: input.url, on: tab)
        case .newTab, .closeTab, .listTabs, .setViewport:
            return .error("Internal routing error for \(input.action.rawValue)")
        }

        if result.success && BrowserAction.visualChangeActions.contains(input.action) {
            result = await appendPostActionDomSummary(result: result, prevURL: prevURL, on: tab)
        }
        tab.syncState()
        return result
    }

    // MARK: - Navigate & Screenshot

    private func navigateAction(url rawURL: String?, on tab: BrowserTab) async -> BrowserActionResult {
        let targetURL: URL
        switch BrowserFormat.normalizeNavigationURL(rawURL) {
        case .invalid(let msg):
            return .error(msg)
        case .ok(let u):
            targetURL = u
        }

        if let prev = tab.navigationContinuation {
            tab.navigationContinuation = nil
            prev.resume()
        }

        tab.lastError = nil
        tab.isLoading = true
        if targetURL.isFileURL {
            tab.webView.loadFileURL(targetURL, allowingReadAccessTo: targetURL.deletingLastPathComponent())
        } else {
            let req = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: BrowserFormat.navigationTimeout)
            tab.webView.load(req)
        }

        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + BrowserFormat.navigationTimeout)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                tab.navigationContinuation = cont
                timer.setEventHandler {
                    Task { @MainActor in
                        if let c = tab.navigationContinuation {
                            tab.navigationContinuation = nil
                            tab.isLoading = false
                            timedOut = true
                            c.resume()
                        }
                    }
                }
                timer.resume()
            }
            timer.cancel()
        } catch {
            timer.cancel()
            tab.isLoading = false
            tab.syncState()
            return .error("Navigation failed: \(error.localizedDescription)")
        }

        tab.isLoading = false
        tab.syncState()
        if tab.currentURL.isEmpty { tab.currentURL = targetURL.absoluteString }

        let metrics = await queryPageMetrics(on: tab)
        let lines = BrowserFormat.pageMetadataLines(
            header: "Navigated to \(tab.currentURL)",
            url: tab.currentURL,
            title: tab.title,
            viewport: tab.viewport,
            pageSize: metrics.pageSize,
            scroll: metrics.scroll
        )
        let meta = lines.joined(separator: "\n")
        if timedOut {
            return BrowserActionResult(
                text: "Navigation did not complete within \(Int(BrowserFormat.navigationTimeout))s — the page may be partially loaded.\n\n\(meta)",
                tabId: tab.id, pageURL: tab.currentURL
            )
        }
        return BrowserActionResult(text: meta, tabId: tab.id, pageURL: tab.currentURL)
    }

    private func screenshotAction(fullPage: Bool, on tab: BrowserTab) async -> BrowserActionResult {
        let vp = tab.viewport
        var captureHeight = Double(vp.height)
        var originalHeight = 0
        var truncated = false

        if fullPage {
            if let raw = try? await evalJSBounded(
                "Math.max(document.documentElement ? document.documentElement.scrollHeight : 0, document.body ? document.body.scrollHeight : 0)",
                timeout: 5, on: tab
            ) as? NSNumber, raw.doubleValue > 0 {
                originalHeight = raw.intValue
                captureHeight = max(Double(vp.height), raw.doubleValue)
                if captureHeight > BrowserFormat.fullPageMaxHeight {
                    captureHeight = BrowserFormat.fullPageMaxHeight
                    truncated = true
                }
            }
        }

        let targetSize = CGSize(width: CGFloat(vp.width), height: CGFloat(captureHeight))
        let savedFrame = tab.webView.frame
        let needsResize = abs(savedFrame.width - targetSize.width) > 0.5 || abs(savedFrame.height - targetSize.height) > 0.5
        if needsResize {
            tab.webView.frame = CGRect(origin: savedFrame.origin, size: targetSize)
            tab.webView.needsLayout = true
            tab.webView.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        defer {
            if needsResize {
                tab.webView.frame = CGRect(origin: savedFrame.origin,
                                           size: CGSize(width: CGFloat(vp.width), height: CGFloat(vp.height)))
                tab.webView.needsLayout = true
                tab.webView.layoutSubtreeIfNeeded()
            }
        }

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: targetSize)

        let nsImage: NSImage
        do {
            nsImage = try await tab.webView.takeSnapshot(configuration: config)
        } catch {
            return .error("Failed to take screenshot: \(error.localizedDescription)")
        }

        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return .error("Failed to encode screenshot as PNG")
        }

        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let fileURL = BrowserFormat.browserDir.appendingPathComponent("screenshot_\(ts).png")
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return .error("Failed to write screenshot: \(error.localizedDescription)")
        }

        tab.syncState()
        let metrics = await queryPageMetrics(on: tab)
        var lines = BrowserFormat.pageMetadataLines(
            header: "Screenshot captured",
            url: tab.currentURL,
            title: tab.title,
            viewport: vp,
            pageSize: metrics.pageSize,
            scroll: metrics.scroll
        )
        lines.insert("  Image: \(Int(targetSize.width))x\(Int(targetSize.height)) (\(BrowserFormat.formatBytes(pngData.count)))", at: min(2, lines.count))
        lines.append("  Saved to: \(fileURL.path)")
        if fullPage {
            lines.append("  Full page: true")
            if truncated && originalHeight > 0 {
                lines.append("  Truncated: true (original height \(originalHeight)px capped at \(Int(BrowserFormat.fullPageMaxHeight))px)")
            }
        }
        return BrowserActionResult(text: lines.joined(separator: "\n"),
                                   success: true, imageFilePath: fileURL.path,
                                   tabId: tab.id, pageURL: tab.currentURL)
    }

    // MARK: - DOM & JS Actions

    private func clickAction(selector: String?, x: Int?, y: Int?, on tab: BrowserTab) async -> BrowserActionResult {
        if let selector {
            return await evaluateReadJS(BrowserUseJS.click(selector: selector), on: tab)
        } else if let x, let y {
            return await evaluateReadJS(BrowserUseJS.clickCoordinate(x: x, y: y), on: tab)
        }
        return .error("click requires 'selector' or 'coordinate_x'/'coordinate_y'")
    }

    private func typeAction(selector: String?, text: String?, on tab: BrowserTab) async -> BrowserActionResult {
        guard let selector else { return .error("type requires 'selector'") }
        guard let text else { return .error("type requires 'text'") }
        return await evaluateReadJS(BrowserUseJS.type(selector: selector, text: text), on: tab)
    }

    private func getBackboneAction(maxDepth: Int?, on tab: BrowserTab) async -> BrowserActionResult {
        let js = BrowserUseJS.getBackbone(maxDepth: maxDepth ?? 5)
        do {
            let raw = try await evalJSBounded(js, timeout: BrowserFormat.readActionTimeout, on: tab)
            guard let json = BrowserFormat.parseJSONObject(raw) else {
                return .error("Failed to parse backbone result")
            }
            if let err = json["error"] as? String { return .error(err) }
            return BrowserActionResult(text: BrowserFormat.formatBackboneResult(json),
                                       tabId: tab.id, pageURL: tab.currentURL)
        } catch {
            return .error(jsErrorMessage(error))
        }
    }

    private func scrollAction(selector: String?, direction: BrowserInput.ScrollDirection?,
                              amount: Int?, on tab: BrowserTab) async -> BrowserActionResult {
        let dir = direction ?? .down
        let px = amount ?? 500
        let js = BrowserUseJS.scroll(direction: dir, amount: px, selector: selector)
        do {
            let raw = try await callAsyncJSBounded(js, timeout: BrowserFormat.readActionTimeout, on: tab)
            if let json = BrowserFormat.parseJSONObject(raw) {
                if let err = json["error"] as? String { return .error(err) }
                return BrowserActionResult(text: BrowserFormat.formatJSONResult(json),
                                           tabId: tab.id, pageURL: tab.currentURL)
            }
            return BrowserActionResult(text: String(describing: raw ?? "null"),
                                       tabId: tab.id, pageURL: tab.currentURL)
        } catch {
            return .error(jsErrorMessage(error))
        }
    }

    private func scrollAndCollectAction(selector: String?, direction: BrowserInput.ScrollDirection?,
                                        amount: Int?, scrollCount: Int?, itemSelector: String?,
                                        on tab: BrowserTab) async -> BrowserActionResult {
        let dir = direction ?? .down
        let px = amount ?? 500
        let count = min(max(1, scrollCount ?? 10), 20)
        let js = BrowserUseJS.scrollAndCollect(direction: dir, amount: px, scrollCount: count,
                                               selector: selector, itemSelector: itemSelector)
        do {
            let raw = try await callAsyncJSBounded(js, timeout: BrowserFormat.executeJSTimeout, on: tab)
            if let json = BrowserFormat.parseJSONObject(raw) {
                if let err = json["error"] as? String { return .error(err) }
                return BrowserActionResult(text: BrowserFormat.formatScrollAndCollectResult(json),
                                           tabId: tab.id, pageURL: tab.currentURL)
            }
            return BrowserActionResult(text: String(describing: raw ?? "null"),
                                       tabId: tab.id, pageURL: tab.currentURL)
        } catch {
            return .error(jsErrorMessage(error))
        }
    }

    private func executeJSAction(script: String?, on tab: BrowserTab) async -> BrowserActionResult {
        guard let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("execute_js requires 'script'")
        }
        let wrapped = BrowserFormat.wrapExecuteJSReturn(script)
        do {
            let raw = try await callAsyncJSBounded(wrapped, timeout: BrowserFormat.executeJSTimeout, on: tab)
            return BrowserActionResult(text: BrowserFormat.stringifyJSReturn(raw),
                                       tabId: tab.id, pageURL: tab.currentURL)
        } catch is JSEvalTimeout {
            return .error("JavaScript timed out after \(Int(BrowserFormat.executeJSTimeout))s.")
        } catch {
            return .error(jsErrorMessage(error))
        }
    }

    private func waitForDomStableAction(timeout: Int?, on tab: BrowserTab) async -> BrowserActionResult {
        let timeoutSec = Double(max(1, timeout ?? 10))
        let setupJS = """
        if (!window.__domStableObserver) {
            window.__domStableCounter = 0;
            window.__domStableObserver = new MutationObserver(function(mutations) {
                for (var i = 0; i < mutations.length; i++) {
                    window.__domStableCounter += mutations[i].addedNodes.length
                        + mutations[i].removedNodes.length
                        + (mutations[i].type === 'attributes' ? 1 : 0)
                        + (mutations[i].type === 'characterData' ? 1 : 0);
                }
            });
            window.__domStableObserver.observe(document.documentElement, {
                childList: true, subtree: true, attributes: true, characterData: true
            });
        }
        window.__domStableCounter = 0;
        return 'ok';
        """
        _ = try? await callAsyncJSBounded(setupJS, timeout: 5, on: tab)

        let start = CFAbsoluteTimeGetCurrent()
        var tracker = BrowserFormat.StabilityTracker(needed: 3)

        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed >= timeoutSec {
                _ = try? await callAsyncJSBounded(
                    "if (window.__domStableObserver) { window.__domStableObserver.disconnect(); window.__domStableObserver = null; } return 'ok';",
                    timeout: 3, on: tab
                )
                return BrowserActionResult(
                    text: "DOM wait timed out after \(String(format: "%.1f", timeoutSec))s (still changing, \(tracker.total) total mutations in \(tracker.samples.count) samples)",
                    tabId: tab.id, pageURL: tab.currentURL
                )
            }
            let readJS = "var c = window.__domStableCounter || 0; window.__domStableCounter = 0; return c;"
            guard let raw = try? await callAsyncJSBounded(readJS, timeout: 3, on: tab) else {
                return BrowserActionResult(
                    text: "DOM stable (page context changed after \(String(format: "%.1f", elapsed))s)",
                    tabId: tab.id, pageURL: tab.currentURL
                )
            }
            let count = (raw as? NSNumber)?.intValue ?? 0
            if tracker.add(count) == .settled {
                _ = try? await callAsyncJSBounded(
                    "if (window.__domStableObserver) { window.__domStableObserver.disconnect(); window.__domStableObserver = null; } return 'ok';",
                    timeout: 3, on: tab
                )
                if count == 0 {
                    return BrowserActionResult(
                        text: "DOM stable after \(String(format: "%.1f", elapsed))s (\(tracker.total) total mutations settled over \(tracker.samples.count) samples)",
                        tabId: tab.id, pageURL: tab.currentURL
                    )
                } else {
                    return BrowserActionResult(
                        text: "DOM stable after \(String(format: "%.1f", elapsed))s (\(tracker.total) total mutations, gradient settled at \(count)/interval over \(tracker.samples.count) samples)",
                        tabId: tab.id, pageURL: tab.currentURL
                    )
                }
            }
        }
    }

    // MARK: - Cookies & Fetch

    private func getCookiesAction(keywords: [String]?, fuzzy: Bool, on tab: BrowserTab) async -> BrowserActionResult {
        guard let pageURL = tab.webView.url ?? URL(string: tab.currentURL),
              let host = pageURL.host, !host.isEmpty else {
            return .error("No page is currently loaded")
        }
        let all = await tab.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let filtered = all.filter { c in
            BrowserFormat.cookieMatchesHost(cookieDomain: c.domain, host: host)
                && BrowserFormat.cookieNameMatches(c.name, keywords: keywords, fuzzy: fuzzy)
        }
        if filtered.isEmpty {
            let msg: String
            if let keywords, !keywords.isEmpty {
                msg = "No cookies found for \(host) matching keywords=\"\(keywords.joined(separator: " "))\" (fuzzy=\(fuzzy))."
            } else {
                msg = "No cookies found for \(host)."
            }
            return BrowserActionResult(text: msg, tabId: tab.id, pageURL: pageURL.absoluteString)
        }

        let pairs = filtered.map { (name: $0.name, value: $0.value) }
        let envBody = BrowserFormat.cookieEnvFile(pairs)
        let ts = Int(Date().timeIntervalSince1970)
        let safeDomain = BrowserFormat.rootDomain(of: host).replacingOccurrences(of: ".", with: "_")
        let envFile = BrowserFormat.offloadsDir.appendingPathComponent("env_cookies_\(safeDomain)_\(ts).sh")
        try? envBody.write(to: envFile, atomically: true, encoding: .utf8)

        var lines: [String] = []
        if let keywords, !keywords.isEmpty {
            lines.append("Retrieved \(filtered.count) cookie(s) for current site \(host) with filter keywords=\"\(keywords.joined(separator: " "))\" (fuzzy=\(fuzzy)).")
        } else {
            lines.append("Retrieved \(filtered.count) cookie(s) for current site \(host).")
        }
        lines.append("")
        lines.append("Stored env file:")
        lines.append("  \(envFile.path)")
        lines.append("")
        lines.append("To use them in shell commands:")
        lines.append("  . \(BrowserFormat.shellSingleQuote(envFile.path)) && command")
        lines.append("")
        lines.append("Available cookie variables:")
        var used = Set<String>()
        for c in filtered {
            var env = BrowserFormat.cookieEnvName(c.name)
            var n = 2
            while used.contains(env) { env = BrowserFormat.cookieEnvName(c.name) + "_\(n)"; n += 1 }
            used.insert(env)
            lines.append("- cookie: \(c.name)")
            lines.append("  env: \(env)")
            lines.append("  value_length: \(c.value.count)")
        }
        lines.append("")
        lines.append("The raw cookie values are stored only in the env file and are not included in this tool response.")
        return BrowserActionResult(text: lines.joined(separator: "\n"), tabId: tab.id, pageURL: pageURL.absoluteString)
    }

    private func setCookiesAction(cookies: [[String: Any]]?, on tab: BrowserTab) async -> BrowserActionResult {
        guard let pageURL = tab.webView.url ?? URL(string: tab.currentURL),
              let defaultDomain = pageURL.host, !defaultDomain.isEmpty else {
            return .error("set_cookies: no page is loaded (navigate first)")
        }
        guard let cookies else {
            return .error("set_cookies: 'cookies' must be a JSON array of cookie objects (e.g. [{\"name\":\"foo\",\"value\":\"bar\"}]).")
        }
        guard !cookies.isEmpty else {
            return .error("set_cookies: 'cookies' array is empty — provide at least one {name, value} object.")
        }

        let store = tab.webView.configuration.websiteDataStore.httpCookieStore
        var setNames: [String] = []
        var domainsTouched = Set<String>()
        var failures: [String] = []

        for raw in cookies {
            guard let props = BrowserFormat.cookieProperties(raw, defaultDomain: defaultDomain),
                  let cookie = HTTPCookie(properties: props) else {
                let n = BrowserFormat.cookieString(raw, ["name"]) ?? "(missing name/value)"
                failures.append(n)
                continue
            }
            await store.setCookie(cookie)
            setNames.append(cookie.name)
            domainsTouched.insert(cookie.domain)
        }

        if setNames.isEmpty {
            return .error("set_cookies: no cookies were set (every entry was invalid: \(failures.joined(separator: ", ")))")
        }
        let domainLabel = domainsTouched.count == 1 ? (domainsTouched.first ?? defaultDomain) : domainsTouched.sorted().joined(separator: ", ")
        var text = "Set \(setNames.count) cookie(s) for \(domainLabel): \(setNames.joined(separator: ", "))"
        if !failures.isEmpty {
            text += "\nSkipped \(failures.count) invalid entry(ies): \(failures.joined(separator: ", "))"
        }
        return BrowserActionResult(text: text, tabId: tab.id, pageURL: pageURL.absoluteString)
    }

    private func fetchAction(url rawURL: String?, on tab: BrowserTab) async -> BrowserActionResult {
        guard let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else {
            return .error("fetch requires 'url' parameter")
        }
        let js = """
        try {
            const resp = await fetch(\(BrowserFormat.jsStringLiteral(rawURL)));
            const buf = await resp.arrayBuffer();
            const bytes = new Uint8Array(buf);
            let binary = '';
            const chunk = 8192;
            for (let i = 0; i < bytes.length; i += chunk) {
                binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
            }
            const b64 = btoa(binary);
            return JSON.stringify({
                base64: b64,
                contentType: resp.headers.get('content-type') || '',
                contentDisposition: resp.headers.get('content-disposition') || '',
                status: resp.status,
                url: resp.url || \(BrowserFormat.jsStringLiteral(rawURL)),
                size: bytes.length
            });
        } catch (e) {
            return JSON.stringify({ error: (e && e.message) ? e.message : String(e) });
        }
        """
        let raw: Any?
        do {
            raw = try await callAsyncJSBounded(js, timeout: BrowserFormat.executeJSTimeout, on: tab)
        } catch {
            return .error("JavaScript fetch failed: \(jsErrorMessage(error))")
        }
        guard let json = BrowserFormat.parseJSONObject(raw) else {
            return .error("Failed to parse fetch result")
        }
        if let err = json["error"] as? String {
            return .error("Fetch failed: \(err)")
        }
        guard let b64 = json["base64"] as? String, let data = Data(base64Encoded: b64) else {
            return .error("Failed to decode fetched data")
        }
        let ct = json["contentType"] as? String ?? ""
        let cd = json["contentDisposition"] as? String ?? ""
        let status = BrowserFormat.int(json["status"])
        let finalURL = json["url"] as? String ?? rawURL
        let size = (json["size"] as? NSNumber)?.intValue ?? data.count
        let ts = Int(Date().timeIntervalSince1970)
        let filename = BrowserFormat.fetchFilename(contentDisposition: cd, finalURL: finalURL, contentType: ct, timestamp: ts)
        let dest = BrowserFormat.downloadsDir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            return .error("Failed to save fetched file: \(error.localizedDescription)")
        }
        let lines = [
            "Fetched \(finalURL)",
            "  Status: \(status)",
            "  Content-Type: \(ct)",
            "  Size: \(BrowserFormat.formatBytes(size))",
            "  Saved to: \(dest.path)"
        ]
        return BrowserActionResult(text: lines.joined(separator: "\n"),
                                   tabId: tab.id, pageURL: tab.currentURL)
    }

    // MARK: - Post-Action DOM Settle & Bounded JS Evaluation

    private func appendPostActionDomSummary(result: BrowserActionResult, prevURL: String,
                                            on tab: BrowserTab) async -> BrowserActionResult {
        let setupJS = """
        window.__postActionDom = {
            mutations: 0, addedTags: {}, removedCount: 0, textChanges: 0, attrChanges: 0,
            newTexts: [], urlBefore: location.href, titleBefore: document.title
        };
        var d = window.__postActionDom;
        if (window.__postActionObserver) { window.__postActionObserver.disconnect(); }
        window.__postActionObserver = new MutationObserver(function(muts) {
            for (var i = 0; i < muts.length; i++) {
                var m = muts[i];
                d.mutations++;
                if (m.type === 'childList') {
                    for (var j = 0; j < m.addedNodes.length; j++) {
                        var n = m.addedNodes[j];
                        if (n.nodeType === 1) {
                            var tag = n.tagName;
                            d.addedTags[tag] = (d.addedTags[tag] || 0) + 1;
                            var txt = (n.innerText || '').trim();
                            if (txt.length > 5 && txt.length < 200 && d.newTexts.length < 5) {
                                d.newTexts.push(txt.substring(0, 100));
                            }
                        }
                    }
                    d.removedCount += m.removedNodes.length;
                } else if (m.type === 'characterData') {
                    d.textChanges++;
                } else if (m.type === 'attributes') {
                    d.attrChanges++;
                }
            }
        });
        window.__postActionObserver.observe(document.documentElement, {
            childList: true, subtree: true, attributes: true, characterData: true
        });
        return 'ok';
        """
        _ = try? await callAsyncJSBounded(setupJS, timeout: 3, on: tab)

        var tracker = BrowserFormat.StabilityTracker(needed: 2)
        var lastTotal = 0
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < 3.0 {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let raw = try? await callAsyncJSBounded(
                "return window.__postActionDom ? window.__postActionDom.mutations : 0;",
                timeout: 2, on: tab
            ) else { break }
            let total = (raw as? NSNumber)?.intValue ?? 0
            let delta = max(0, total - lastTotal)
            lastTotal = total
            if tracker.add(delta) == .settled { break }
        }

        let readJS = """
        if (window.__postActionObserver) {
            window.__postActionObserver.disconnect();
            window.__postActionObserver = null;
        }
        var d = window.__postActionDom || {};
        return JSON.stringify({
            mutations: d.mutations || 0,
            addedTags: d.addedTags || {},
            removedCount: d.removedCount || 0,
            textChanges: d.textChanges || 0,
            attrChanges: d.attrChanges || 0,
            newTexts: d.newTexts || [],
            urlChanged: (location.href !== (d.urlBefore || '')),
            urlNow: location.href,
            titleNow: document.title
        });
        """
        var out = result
        if let raw = try? await callAsyncJSBounded(readJS, timeout: 2, on: tab),
           let info = BrowserFormat.parseJSONObject(raw) {
            let summary = BrowserFormat.formatDomSummary(info)
            if !summary.isEmpty { out.text += "\n" + summary }
        }
        tab.syncState()
        let curURL = tab.currentURL
        if !prevURL.isEmpty, !curURL.isEmpty,
           BrowserFormat.stripHash(prevURL) != BrowserFormat.stripHash(curURL) {
            out.text += "\n[URL Changed] Page navigated: \(prevURL) -> \(curURL)."
        }
        return out
    }

    private func queryPageMetrics(on tab: BrowserTab) async -> (pageSize: (Int, Int), scroll: (Int, Int)) {
        let js = "JSON.stringify({sx:Math.round(window.scrollX||0),sy:Math.round(window.scrollY||0),pw:document.documentElement?document.documentElement.scrollWidth:0,ph:document.documentElement?document.documentElement.scrollHeight:0})"
        if let raw = try? await evalJSBounded(js, timeout: 5, on: tab),
           let info = BrowserFormat.parseJSONObject(raw) {
            let pw = BrowserFormat.int(info["pw"]), ph = BrowserFormat.int(info["ph"])
            let sx = BrowserFormat.int(info["sx"]), sy = BrowserFormat.int(info["sy"])
            return ((pw, ph), (sx, sy))
        }
        return ((0, 0), (0, 0))
    }

    private func evaluateReadJS(_ js: String, on tab: BrowserTab) async -> BrowserActionResult {
        do {
            let raw = try await evalJSBounded(js, timeout: BrowserFormat.readActionTimeout, on: tab)
            if let str = raw as? String {
                if let json = BrowserFormat.parseJSONObject(str) {
                    if let err = json["error"] as? String { return .error(err) }
                    return BrowserActionResult(text: BrowserFormat.formatJSONResult(json),
                                               tabId: tab.id, pageURL: tab.currentURL)
                }
                return BrowserActionResult(text: str, tabId: tab.id, pageURL: tab.currentURL)
            }
            return BrowserActionResult(text: String(describing: raw ?? "null"),
                                       tabId: tab.id, pageURL: tab.currentURL)
        } catch is JSEvalTimeout {
            return .error("Timed out after \(Int(BrowserFormat.readActionTimeout))s reading the page.")
        } catch {
            return .error(jsErrorMessage(error))
        }
    }

    private struct JSEvalTimeout: Error {}

    private final class EvalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var cont: CheckedContinuation<Any?, Error>?
        var onFinish: (() -> Void)?

        func finish(_ result: Result<Any?, Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont; cont = nil
            let cleanup = onFinish; onFinish = nil
            lock.unlock()
            cleanup?()
            switch result {
            case .success(let v): c?.resume(returning: v)
            case .failure(let e): c?.resume(throwing: e)
            }
        }
    }

    private func evalJSBounded(_ js: String, timeout: TimeInterval, on tab: BrowserTab) async throws -> Any? {
        let box = EvalBox()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { box.finish(.failure(JSEvalTimeout())) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            box.cont = cont
            box.onFinish = { timer.cancel() }
            timer.resume()
            tab.webView.evaluateJavaScript(js) { value, error in
                if let error { box.finish(.failure(error)) }
                else { box.finish(.success(value)) }
            }
        }
    }

    private func callAsyncJSBounded(_ js: String, timeout: TimeInterval, on tab: BrowserTab) async throws -> Any? {
        let box = EvalBox()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { box.finish(.failure(JSEvalTimeout())) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            box.cont = cont
            let evalTask = Task { @MainActor in
                do {
                    let v = try await tab.webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
                    box.finish(.success(v))
                } catch {
                    box.finish(.failure(error))
                }
            }
            box.onFinish = { timer.cancel(); evalTask.cancel() }
            timer.resume()
        }
    }

    private func jsErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        if let msg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String, !msg.isEmpty {
            return "JavaScript error: \(msg)"
        }
        return error.localizedDescription
    }
}
