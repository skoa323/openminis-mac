import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM binary; harmless inside a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OpenMinisMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    var body: some Scene {
        Window("OpenMinis", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 500)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveConversations()
                    AgentJobRegistry.shared.saveToDisk()
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话") { store.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("在对话中查找") { store.sendFind(.open) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("查找下一个") { store.sendFind(.next) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("查找上一个") { store.sendFind(.previous) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("搜索所有对话") { store.sidebarSearchFocus += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Window("内置浏览器", id: "browser") {
            BrowserPanelView()
        }
        .defaultSize(width: 1040, height: 720)

        MenuBarExtra("OpenMinis",
                     systemImage: keepAlive.hasActiveWork ? "bolt.horizontal.circle.fill" : "sparkles",
                     isInserted: $keepAlive.showMenuBarExtra) {
            MenuBarJobsView()
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
