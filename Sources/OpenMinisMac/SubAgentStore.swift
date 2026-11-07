import Foundation
import AppKit
import UserNotifications

// Port of upstream Providers/SubAgentStore.swift and macOS adaptation of Agent/Background
// (BackgroundKeepAliveManager + AgentLiveActivityManager → ProcessInfo activity assertion,
// UNUserNotificationCenter completion notices, and MenuBarExtra status tracking).

@MainActor
final class SubAgentStore: ObservableObject {
    static let shared = SubAgentStore()

    @Published private(set) var subAgents: [SubAgentDefinition] = []

    nonisolated static var fileURL: URL {
        AppStore.supportDir.appendingPathComponent("sub-agents.json")
    }

    init() {
        self.subAgents = Self.load(from: Self.fileURL)
    }

    private static func load(from url: URL) -> [SubAgentDefinition] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let decoded = try? dec.decode([SubAgentDefinition].self, from: data) else {
            return SubAgentRoster.normalize([])
        }
        return SubAgentRoster.normalize(decoded)
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(subAgents) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func reloadFromDisk() {
        subAgents = Self.load(from: Self.fileURL)
    }

    func subAgent(id: String) -> SubAgentDefinition? {
        subAgents.first { $0.id == id }
    }

    func subAgentNameIsTaken(_ name: String, excluding id: String?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = SubAgentRoster.nameKey(trimmed)
        return subAgents.contains { $0.id != id && SubAgentRoster.nameKey($0.name) == key }
    }

    var canAddSubAgent: Bool {
        subAgents.count < SubAgentLimits.maxCount
    }

    func upsertSubAgent(_ definition: SubAgentDefinition) {
        var list = subAgents
        var incoming = definition.clamped()
        incoming.updatedAt = Date()
        if incoming.isBuiltIn || incoming.id == SubAgentDefinition.builtInId {
            let canonical = SubAgentDefinition.makeBuiltIn()
            incoming.id = canonical.id
            incoming.name = canonical.name
            incoming.description = canonical.description
            incoming.isBuiltIn = true
        }
        if let idx = list.firstIndex(where: { $0.id == incoming.id }) {
            incoming.sortOrder = list[idx].sortOrder
            list[idx] = incoming
        } else {
            guard list.count < SubAgentLimits.maxCount else { return }
            incoming.sortOrder = list.count
            list.append(incoming)
        }
        subAgents = SubAgentRoster.normalize(list)
        persist()
    }

    func removeSubAgent(id: String) {
        guard id != SubAgentDefinition.builtInId else { return }
        var list = subAgents
        guard list.contains(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        subAgents = SubAgentRoster.normalize(list)
        persist()
    }

    func reorderSubAgents(_ orderedIds: [String]) {
        let byId = Dictionary(uniqueKeysWithValues: subAgents.map { ($0.id, $0) })
        var list: [SubAgentDefinition] = []
        if let builtIn = byId[SubAgentDefinition.builtInId] {
            list.append(builtIn)
        }
        for id in orderedIds where id != SubAgentDefinition.builtInId {
            if let d = byId[id] { list.append(d) }
        }
        for d in subAgents where d.id != SubAgentDefinition.builtInId && !orderedIds.contains(d.id) {
            list.append(d)
        }
        for i in list.indices { list[i].sortOrder = i }
        subAgents = SubAgentRoster.normalize(list)
        persist()
    }

    func moveCustom(at index: Int, delta: Int) {
        let target = index + delta
        guard index >= 1, target >= 1, index < subAgents.count, target < subAgents.count else { return }
        var list = subAgents
        list.swapAt(index, target)
        for i in list.indices { list[i].sortOrder = i }
        subAgents = SubAgentRoster.normalize(list)
        persist()
    }

    func clearModelGroup(_ groupID: UUID) {
        var changed = false
        var list = subAgents
        for i in list.indices where list[i].modelGroupID == groupID {
            list[i].modelGroupID = nil
            list[i].updatedAt = Date()
            changed = true
        }
        if changed {
            subAgents = SubAgentRoster.normalize(list)
            persist()
        }
    }
}

// MARK: - macOS Background Keep-Alive & Status Manager (Agent/Background port)

@MainActor
final class BackgroundKeepAliveManager: ObservableObject {
    static let shared = BackgroundKeepAliveManager()

    @Published var preventSleepWhileActive: Bool {
        didSet {
            UserDefaults.standard.set(preventSleepWhileActive, forKey: Self.preventSleepKey)
            reconcileAssertion()
        }
    }
    @Published var showMenuBarExtra: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarExtra, forKey: Self.menuBarKey)
        }
    }
    @Published var notifyOnBackgroundCompletion: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnBackgroundCompletion, forKey: Self.notifyKey)
        }
    }

    @Published private(set) var runningConversationsCount: Int = 0
    @Published private(set) var runningSubAgentsCount: Int = 0
    @Published private(set) var armedTimersCount: Int = 0
    @Published private(set) var isHoldingSleepAssertion: Bool = false

    private var activityToken: NSObjectProtocol?
    private static let preventSleepKey = "OpenMinisMac.preventSleepWhileActive"
    private static let menuBarKey = "OpenMinisMac.showMenuBarExtra"
    private static let notifyKey = "OpenMinisMac.notifyOnBackgroundCompletion"

    private init() {
        let d = UserDefaults.standard
        self.preventSleepWhileActive = d.object(forKey: Self.preventSleepKey) as? Bool ?? true
        self.showMenuBarExtra = d.object(forKey: Self.menuBarKey) as? Bool ?? true
        self.notifyOnBackgroundCompletion = d.object(forKey: Self.notifyKey) as? Bool ?? true
    }

    var hasActiveWork: Bool {
        runningConversationsCount > 0 || runningSubAgentsCount > 0 || armedTimersCount > 0
    }

    var statusSummary: String {
        var parts: [String] = []
        if runningConversationsCount > 0 { parts.append("\(runningConversationsCount) 对话运行中") }
        if runningSubAgentsCount > 0 { parts.append("\(runningSubAgentsCount) 子代理运行中") }
        if armedTimersCount > 0 { parts.append("\(armedTimersCount) 定时任务待命") }
        return parts.isEmpty ? "空闲" : parts.joined(separator: " · ")
    }

    func updateCounts(conversations: Int, subAgents: Int, timers: Int) {
        runningConversationsCount = max(0, conversations)
        runningSubAgentsCount = max(0, subAgents)
        armedTimersCount = max(0, timers)
        reconcileAssertion()
    }

    private func reconcileAssertion() {
        let shouldHold = preventSleepWhileActive && hasActiveWork
        if shouldHold && activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "OpenMinis background sub-agents and scheduled tasks"
            )
            isHoldingSleepAssertion = true
        } else if !shouldHold, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
            isHoldingSleepAssertion = false
        }
    }

    func notifyCompletionIfNeeded(title: String, body: String) {
        guard notifyOnBackgroundCompletion, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(200))
            content.sound = .default
            let req = UNNotificationRequest(identifier: "om-job-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
    }
}
