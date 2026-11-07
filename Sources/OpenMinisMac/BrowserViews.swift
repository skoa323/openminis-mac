import SwiftUI
import AppKit
import WebKit

// MARK: - NSViewRepresentable WKWebView Container

struct BrowserWebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        embed(webView, in: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            embed(webView, in: nsView)
        }
    }

    private func embed(_ wv: WKWebView, in host: NSView) {
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            wv.topAnchor.constraint(equalTo: host.topAnchor),
            wv.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

// MARK: - Browser Panel View

struct BrowserPanelView: View {
    @ObservedObject var browser = BrowserManager.shared
    var onClose: (() -> Void)? = nil

    @State private var addressInput: String = ""
    @State private var showHistoryPopover: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            navigationBar
            Divider()
            contentArea
        }
        .frame(minWidth: 780, minHeight: 540)
        .onAppear {
            if browser.tabs.isEmpty {
                _ = browser.createTabForUI()
            }
            addressInput = browser.currentURL
        }
        .onChange(of: browser.selectedTabId) { _, _ in
            addressInput = browser.currentURL
        }
        .onChange(of: browser.currentURL) { _, newURL in
            addressInput = newURL
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(browser.tabs) { tab in
                        BrowserTabChip(
                            tab: tab,
                            isSelected: tab.id == (browser.selectedTabId ?? browser.tabs.first?.id),
                            onSelect: { browser.selectTab(tab.id) },
                            onClose: { browser.closeTabForUI(tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Button {
                _ = browser.createTabForUI()
                addressInput = ""
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(browser.tabs.count >= BrowserFormat.maxTabs)
            .help("新建标签页（最多 \(BrowserFormat.maxTabs) 个）")

            Spacer(minLength: 4)

            if let active = browser.activeTab {
                Label(active.profile == .desktopSafari ? "桌面 UA" : "移动 UA",
                      systemImage: active.profile.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }

            if let onClose {
                Button("关闭") { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.trailing, 10)
            }
        }
        .background(Color.secondary.opacity(0.06))
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!browser.canGoBack)
            .help("后退")

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!browser.canGoForward)
            .help("前进")

            if browser.isLoading {
                Button { browser.stopLoading() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("停止加载")
            } else {
                Button { browser.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(browser.activeTab == nil)
                .help("刷新")
            }

            HStack(spacing: 6) {
                if browser.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                TextField("输入网址或搜索词…", text: $addressInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit {
                        browser.loadAddressBar(addressInput)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            Button {
                showHistoryPopover.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help("浏览历史")
            .popover(isPresented: $showHistoryPopover, arrowEdge: .bottom) {
                BrowserHistoryPopover { url in
                    showHistoryPopover = false
                    addressInput = url
                    browser.loadAddressBar(url)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var contentArea: some View {
        if let tab = browser.activeTab {
            ZStack(alignment: .bottom) {
                BrowserWebViewContainer(webView: tab.webView)
                    .id(ObjectIdentifier(tab.webView))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let err = tab.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(err)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Button("重试") { browser.reload() }
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(.regularMaterial)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "safari")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("暂无打开的标签页")
                    .foregroundStyle(.secondary)
                Button("新建标签页") {
                    _ = browser.createTabForUI()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Tab Chip & History Popover

private struct BrowserTabChip: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var label: String {
        if !tab.title.isEmpty { return tab.title }
        if !tab.currentURL.isEmpty { return tab.currentURL }
        return "新标签页 #\(tab.id)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Text("#\(tab.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("关闭标签页")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct BrowserHistoryPopover: View {
    @ObservedObject var browser = BrowserManager.shared
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近浏览记录")
                    .font(.headline)
                Spacer()
                if !browser.history.isEmpty {
                    Button("清空", role: .destructive) {
                        browser.clearHistory()
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            Divider()
            if browser.history.isEmpty {
                Text("暂无浏览历史")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(browser.history) { item in
                    Button {
                        onSelect(item.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? item.domain : item.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(item.url)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 360, height: 320)
    }
}

// MARK: - BrowserSettings Tab (in SettingsView)

struct BrowserSettings: View {
    @ObservedObject var browser = BrowserManager.shared
    @State private var cookieCount: Int = 0
    @State private var clearedNotice: String? = nil

    var body: some View {
        Form {
            Section("默认 User-Agent") {
                Picker("User-Agent 配置", selection: $browser.defaultProfile) {
                    ForEach(UserAgentProfile.allCases) { p in
                        Label("\(p.label)（\(p.viewportSize.width)×\(p.viewportSize.height)）", systemImage: p.icon)
                            .tag(p)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(browser.defaultProfile.userAgentString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("活动标签页（\(browser.tabs.count)/\(BrowserFormat.maxTabs)）") {
                if browser.tabs.isEmpty {
                    Text("当前没有打开的浏览器标签页")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(browser.tabs) { tab in
                        HStack {
                            Text("#\(tab.id)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title.isEmpty ? "（无标题）" : tab.title)
                                    .lineLimit(1)
                                Text(tab.currentURL.isEmpty ? "about:blank" : tab.currentURL)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("关闭", role: .destructive) {
                                browser.closeTabForUI(tab.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("网站数据与 Cookie") {
                HStack {
                    Text("已存储 Cookie 数量：\(cookieCount)")
                    Spacer()
                    Button("刷新统计") {
                        Task { await refreshCookieCount() }
                    }
                    .controlSize(.small)
                    Button("清除 Cookie 与网站数据", role: .destructive) {
                        Task {
                            await browser.clearCookiesAndData()
                            await refreshCookieCount()
                            clearedNotice = "已清除所有 Cookie 与网站数据"
                        }
                    }
                    .controlSize(.small)
                }
                if let clearedNotice {
                    Text(clearedNotice)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("浏览历史（最近 7 天，共 \(browser.history.count) 条）") {
                if browser.history.isEmpty {
                    Text("暂无浏览历史记录")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Spacer()
                        Button("清空浏览历史", role: .destructive) {
                            browser.clearHistory()
                        }
                        .controlSize(.small)
                    }
                    ForEach(browser.history.prefix(30)) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title.isEmpty ? item.domain : item.title)
                                    .lineLimit(1)
                                Text(item.url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(item.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await refreshCookieCount()
        }
    }

    private func refreshCookieCount() async {
        let all = await browser.allCookies()
        cookieCount = all.count
    }
}
