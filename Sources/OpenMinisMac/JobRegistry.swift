import Foundation
import SwiftUI

// Port of upstream Agent/Jobs: AgentJobRegistry.swift, HelperRunner.swift,
// ScheduledJobRunner.swift & SubAgentTermination.swift.

extension Notification.Name {
    static let agentJobDidFinish = Notification.Name("OpenMinisMac.agentJobDidFinish")
}

enum AgentJobOrigin: String, Codable, Sendable {
    case tool
    case cli
    case ui
}

enum AgentJobTrigger: Codable, Equatable, Sendable {
    case immediate
    case once(after: TimeInterval)
    case loop(interval: TimeInterval, count: Int?)
    case cron(hour: Int, minute: Int, days: Set<Int>, start: Date?, end: Date?)
    case onCompletion(ofJobId: String)

    var logLabel: String {
        switch self {
        case .immediate: return "immediate"
        case .once(let after): return "once(+\(Int(after))s)"
        case .loop(let interval, let count):
            return "loop(\(Int(interval))s×\(count.map(String.init) ?? "∞"))"
        case .cron(let h, let m, let days, _, _):
            return "cron(\(String(format: "%02d:%02d", h, m)) days=\(days.sorted()))"
        case .onCompletion(let id):
            return "onCompletion(\(id.prefix(8)))"
        }
    }
}

enum AgentJobTarget: Codable, Equatable, Sendable {
    case new
    case followUp(conversationID: UUID)
    case rerun(conversationID: UUID, messageID: UUID)
    case childOfCurrent(parentConversationID: UUID, parentToolUseID: String?)

    var isChildOfCurrent: Bool {
        if case .childOfCurrent = self { return true }
        return false
    }

    var parentConversationID: UUID? {
        if case .childOfCurrent(let p, _) = self { return p }
        return nil
    }
}

enum AgentJobState: String, Codable, Sendable {
    case queued
    case pending
    case running
    case done
    case cancelled
    case failed
    case timeout
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .failed, .timeout, .interrupted: return true
        case .queued, .pending, .running: return false
        }
    }
}

@MainActor
final class AgentJob: Identifiable, ObservableObject, Codable {
    let id: String
    var label: String?
    let origin: AgentJobOrigin
    var trigger: AgentJobTrigger
    var target: AgentJobTarget
    var prompt: String?
    var title: String

    @Published var state: AgentJobState = .pending
    @Published var firedCount: Int = 0
    @Published var remaining: Int? = nil
    @Published var skippedCount: Int = 0
    @Published var isEnabled: Bool = true
    @Published var nextFireAt: Date? = nil
    @Published var fireInFlight: Bool = false

    // Sub-agent specific tracking
    var subAgentId: String? = nil
    var subAgentName: String? = nil
    var modelOrigin: String? = nil
    var modelResolvedLabel: String? = nil
    var modelGroupUnavailable: Bool = false
    var maxMinutes: Int = SubAgentLimits.defaultMaxMinutes
    var progressCadence: ProgressReportCadence = .none
    var deliverToParentOnFinish: Bool = true
    var creatorConversationID: UUID? = nil
    var runConversationID: UUID? = nil
    var createdAt: Date = Date()
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    @Published var currentTool: String = ""
    @Published var turnsCount: Int = 0
    @Published var toolCallsSummary: [String: Int] = [:]
    @Published var resultText: String? = nil
    var pendingSteers: [String] = []
    var appliedSteers: [String] = []
    var missedSteers: [String] = []
    var wasResumed: Bool = false
    var presetToolCall: ScheduledPresetToolCall? = nil
    var thinkingLevel: ThinkingLevel? = nil

    // Non-persisted runtime handles
    var task: Task<Void, Never>? = nil
    var progressTask: Task<Void, Never>? = nil
    var timeoutTask: Task<Void, Never>? = nil

    init(id: String = UUID().uuidString.uppercased(),
         label: String? = nil,
         origin: AgentJobOrigin,
         trigger: AgentJobTrigger,
         target: AgentJobTarget,
         prompt: String?,
         title: String,
         state: AgentJobState = .pending) {
        self.id = id
        self.label = label
        self.origin = origin
        self.trigger = trigger
        self.target = target
        self.prompt = prompt
        self.title = title
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, origin, trigger, target, prompt, title, state, firedCount, remaining,
             skippedCount, isEnabled, nextFireAt, subAgentId, subAgentName, modelOrigin,
             modelResolvedLabel, modelGroupUnavailable, maxMinutes, progressCadence,
             deliverToParentOnFinish, creatorConversationID, runConversationID, createdAt,
             startedAt, endedAt, currentTool, turnsCount, toolCallsSummary, resultText,
             pendingSteers, appliedSteers, missedSteers, wasResumed, presetToolCall, thinkingLevel
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.uppercased()
        let label = try c.decodeIfPresent(String.self, forKey: .label)
        let origin = (try? c.decode(AgentJobOrigin.self, forKey: .origin)) ?? .tool
        let trigger = (try? c.decode(AgentJobTrigger.self, forKey: .trigger)) ?? .immediate
        let target = (try? c.decode(AgentJobTarget.self, forKey: .target)) ?? .new
        let prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Job"
        let rawState = (try? c.decode(AgentJobState.self, forKey: .state)) ?? .pending
        self.init(id: id, label: label, origin: origin, trigger: trigger, target: target, prompt: prompt, title: title, state: rawState)
        firedCount = try c.decodeIfPresent(Int.self, forKey: .firedCount) ?? 0
        remaining = try c.decodeIfPresent(Int.self, forKey: .remaining)
        skippedCount = try c.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        nextFireAt = try c.decodeIfPresent(Date.self, forKey: .nextFireAt)
        subAgentId = try c.decodeIfPresent(String.self, forKey: .subAgentId)
        subAgentName = try c.decodeIfPresent(String.self, forKey: .subAgentName)
        modelOrigin = try c.decodeIfPresent(String.self, forKey: .modelOrigin)
        modelResolvedLabel = try c.decodeIfPresent(String.self, forKey: .modelResolvedLabel)
        modelGroupUnavailable = try c.decodeIfPresent(Bool.self, forKey: .modelGroupUnavailable) ?? false
        maxMinutes = try c.decodeIfPresent(Int.self, forKey: .maxMinutes) ?? SubAgentLimits.defaultMaxMinutes
        progressCadence = (try? c.decode(ProgressReportCadence.self, forKey: .progressCadence)) ?? .none
        deliverToParentOnFinish = try c.decodeIfPresent(Bool.self, forKey: .deliverToParentOnFinish) ?? true
        creatorConversationID = try c.decodeIfPresent(UUID.self, forKey: .creatorConversationID)
        runConversationID = try c.decodeIfPresent(UUID.self, forKey: .runConversationID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        currentTool = try c.decodeIfPresent(String.self, forKey: .currentTool) ?? ""
        turnsCount = try c.decodeIfPresent(Int.self, forKey: .turnsCount) ?? 0
        toolCallsSummary = try c.decodeIfPresent([String: Int].self, forKey: .toolCallsSummary) ?? [:]
        resultText = try c.decodeIfPresent(String.self, forKey: .resultText)
        pendingSteers = try c.decodeIfPresent([String].self, forKey: .pendingSteers) ?? []
        appliedSteers = try c.decodeIfPresent([String].self, forKey: .appliedSteers) ?? []
        missedSteers = try c.decodeIfPresent([String].self, forKey: .missedSteers) ?? []
        wasResumed = try c.decodeIfPresent(Bool.self, forKey: .wasResumed) ?? false
        presetToolCall = try? c.decodeIfPresent(ScheduledPresetToolCall.self, forKey: .presetToolCall)
        thinkingLevel = try? c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(origin, forKey: .origin)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encode(title, forKey: .title)
        try c.encode(state, forKey: .state)
        try c.encode(firedCount, forKey: .firedCount)
        try c.encodeIfPresent(remaining, forKey: .remaining)
        try c.encode(skippedCount, forKey: .skippedCount)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(nextFireAt, forKey: .nextFireAt)
        try c.encodeIfPresent(subAgentId, forKey: .subAgentId)
        try c.encodeIfPresent(subAgentName, forKey: .subAgentName)
        try c.encodeIfPresent(modelOrigin, forKey: .modelOrigin)
        try c.encodeIfPresent(modelResolvedLabel, forKey: .modelResolvedLabel)
        try c.encode(modelGroupUnavailable, forKey: .modelGroupUnavailable)
        try c.encode(maxMinutes, forKey: .maxMinutes)
        try c.encode(progressCadence, forKey: .progressCadence)
        try c.encode(deliverToParentOnFinish, forKey: .deliverToParentOnFinish)
        try c.encodeIfPresent(creatorConversationID, forKey: .creatorConversationID)
        try c.encodeIfPresent(runConversationID, forKey: .runConversationID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(currentTool, forKey: .currentTool)
        try c.encode(turnsCount, forKey: .turnsCount)
        try c.encode(toolCallsSummary, forKey: .toolCallsSummary)
        try c.encodeIfPresent(resultText, forKey: .resultText)
        try c.encode(pendingSteers, forKey: .pendingSteers)
        try c.encode(appliedSteers, forKey: .appliedSteers)
        try c.encode(missedSteers, forKey: .missedSteers)
        try c.encode(wasResumed, forKey: .wasResumed)
        try c.encodeIfPresent(presetToolCall, forKey: .presetToolCall)
        try c.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
    }

    var isSubAgentJob: Bool {
        target.isChildOfCurrent && trigger == .immediate
    }

    var isScheduledTimer: Bool {
        trigger != .immediate
    }

    var elapsedSeconds: TimeInterval {
        guard let start = startedAt else { return 0 }
        return (endedAt ?? Date()).timeIntervalSince(start)
    }

    var summaryString: String {
        let toolsDesc: String
        if toolCallsSummary.isEmpty {
            toolsDesc = "tools none"
        } else {
            let parts = toolCallsSummary.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            toolsDesc = "tools " + parts.joined(separator: ", ")
        }
        return "\(toolsDesc) · turns \(turnsCount) · elapsed \(ScheduleParser.formatElapsed(elapsedSeconds))"
    }
}

// MARK: - AgentJobRegistry (Sub-Agents & Scheduled Tasks)

@MainActor
final class AgentJobRegistry: ObservableObject {
    static let shared = AgentJobRegistry()
    static let maxChildJobsPerParent = SubAgentLimits.maxChildJobsPerParent

    @Published private(set) var jobs: [AgentJob] = []
    weak var store: AppStore?

    nonisolated static var jobsFileURL: URL {
        AppStore.supportDir.appendingPathComponent("jobs.json")
    }

    private init() {
        self.jobs = Self.loadFromDisk()
    }

    func attach(store: AppStore) {
        self.store = store
        // Re-arm pending scheduled timers that survived across launches
        for job in jobs where job.isScheduledTimer && job.state == .pending && job.isEnabled {
            armScheduledJob(job)
        }
        syncKeepAliveCounts()
    }

    private static func loadFromDisk() -> [AgentJob] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: jobsFileURL),
              let loaded = try? dec.decode([AgentJob].self, from: data) else {
            return []
        }
        // Any sub-agent that was running/queued when the app exited becomes `interrupted` so `action="resume"` can restart it.
        for j in loaded where j.isSubAgentJob && (j.state == .running || j.state == .queued || j.state == .pending) {
            j.state = .interrupted
            j.endedAt = Date()
        }
        return loaded
    }

    func saveToDisk() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        // Keep last 200 jobs
        let trimmed = jobs.count > 200 ? Array(jobs.suffix(200)) : jobs
        if let data = try? enc.encode(trimmed) {
            try? data.write(to: Self.jobsFileURL, options: .atomic)
        }
        syncKeepAliveCounts()
    }

    func syncKeepAliveCounts() {
        let convs = store?.runningIDs.count ?? 0
        let subs = jobs.filter { $0.isSubAgentJob && ($0.state == .running || $0.state == .queued) }.count
        let timers = jobs.filter { $0.isScheduledTimer && $0.state == .pending && $0.isEnabled }.count
        BackgroundKeepAliveManager.shared.updateCounts(conversations: convs, subAgents: subs, timers: timers)
    }

    // MARK: - Queries

    func job(matchingPrefix prefixRaw: String, in parentID: UUID? = nil) -> AgentJob? {
        let p = prefixRaw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !p.isEmpty else { return nil }
        return jobs.last { j in
            let matchesID = j.id.uppercased() == p || j.id.uppercased().hasPrefix(p)
            guard matchesID else { return false }
            if let parentID {
                return j.target.parentConversationID == parentID || j.creatorConversationID == parentID
            }
            return true
        }
    }

    func subAgentJobs(for parentID: UUID) -> [AgentJob] {
        jobs.filter { $0.isSubAgentJob && $0.target.parentConversationID == parentID }
    }

    func scheduledJobs(for conversationID: UUID) -> [AgentJob] {
        jobs.filter { j in
            guard j.isScheduledTimer && j.state == .pending else { return false }
            if j.creatorConversationID == conversationID { return true }
            switch j.target {
            case .followUp(let cid), .rerun(let cid, _), .childOfCurrent(let cid, _):
                return cid == conversationID
            case .new:
                return false
            }
        }
    }

    func runningChildCount(for parentID: UUID) -> Int {
        jobs.filter { $0.isSubAgentJob && $0.target.parentConversationID == parentID && $0.state == .running }.count
    }

    func canStartChildJob(for parentID: UUID) -> Bool {
        runningChildCount(for: parentID) < Self.maxChildJobsPerParent
    }

    /// One-line summary of sibling sub-agents for `<other_sub_agents>` in callbacks.
    func siblingStatusLine(for parentID: UUID, excluding jobId: String) -> String? {
        let others = subAgentJobs(for: parentID).filter { $0.id != jobId }
        let running = others.filter { $0.state == .running }.count
        let queued = others.filter { $0.state == .queued }.count
        let interrupted = others.filter { $0.state == .interrupted }.count
        guard running > 0 || queued > 0 || interrupted > 0 else { return nil }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if queued > 0 { parts.append("\(queued) queued") }
        if interrupted > 0 { parts.append("\(interrupted) interrupted") }
        return "Other sub agents in this conversation: " + parts.joined(separator: ", ") + "."
    }

    // MARK: - Sub-Agent Tool Dispatcher (`subagent_task`)

    func runSubAgentTool(args: [String: Any], parentConversationID: UUID, toolUseID: String) async -> ToolResult {
        let action = (args["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "delegate"
        switch action {
        case "delegate":
            return await delegateSubAgent(args: args, parentID: parentConversationID, toolUseID: toolUseID)
        case "status":
            return statusSubAgents(args: args, parentID: parentConversationID)
        case "steer":
            return steerSubAgent(args: args, parentID: parentConversationID)
        case "cancel":
            return await cancelSubAgent(args: args, parentID: parentConversationID)
        case "resume":
            return await resumeSubAgents(args: args, parentID: parentConversationID)
        default:
            return ToolResult(output: "Error: unknown subagent_task action '\(action)'. Valid actions: delegate, status, steer, cancel, resume.", isError: true)
        }
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - action = delegate

    private func delegateSubAgent(args: [String: Any], parentID: UUID, toolUseID: String) async -> ToolResult {
        guard let store else { return ToolResult(output: "Error: store unavailable", isError: true) }
        guard let taskText = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !taskText.isEmpty else {
            return ToolResult(output: "Error: subagent_task action=delegate requires a non-empty 'task' string.", isError: true)
        }
        let toolTitle = (args["tool_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Sub-agent task"
        let agentNameRaw = args["agent"] as? String
        let subAgentDef = SubAgentRoster.resolve(name: agentNameRaw, in: SubAgentStore.shared.subAgents)
        let modelChoice = SubAgentModelChoice.parse(args["model_choice"] as? String)
        let contextExtra = (args["context"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let maxMinutes = min(SubAgentLimits.maxMinutesCap, max(1, (args["max_minutes"] as? Int) ?? SubAgentLimits.defaultMaxMinutes))
        let wait = (args["wait"] as? Bool) ?? false
        let cadence = wait ? .none : ProgressReportCadence.parse(args["progress_report"] as? String)

        let resolved = resolveModelForSubAgent(def: subAgentDef, parentID: parentID, choice: modelChoice, store: store)

        var fullBrief = taskText
        if !subAgentDef.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fullBrief += "\n\n---\nSub-Agent Instructions (\(subAgentDef.name)):\n" + subAgentDef.instructions
        }
        if !contextExtra.isEmpty {
            fullBrief += "\n\n---\nContext:\n" + contextExtra
        }

        // Create hidden child conversation
        var childConv = Conversation()
        childConv.title = "🤖 \(toolTitle)"
        childConv.parentConversationID = parentID
        childConv.parentToolUseID = toolUseID
        childConv.groupID = resolved.groupID
        childConv.thinkingLevel = subAgentDef.thinkingLevelOverride ?? store.thinking(for: parentID)
        childConv.memoryEnabled = false
        if let parentConv = store.conversation(parentID) {
            childConv.skillOverrides = parentConv.skillOverrides
        }
        store.conversations.insert(childConv, at: 0)
        store.saveConversations()

        let job = AgentJob(
            label: toolTitle,
            origin: .tool,
            trigger: .immediate,
            target: .childOfCurrent(parentConversationID: parentID, parentToolUseID: toolUseID),
            prompt: fullBrief,
            title: toolTitle,
            state: .queued
        )
        job.subAgentId = subAgentDef.id
        job.subAgentName = subAgentDef.name
        job.modelOrigin = resolved.origin.rawValue
        job.modelResolvedLabel = resolved.label
        job.modelGroupUnavailable = resolved.groupUnavailable
        job.maxMinutes = maxMinutes
        job.progressCadence = cadence
        job.deliverToParentOnFinish = !wait
        job.creatorConversationID = parentID
        job.runConversationID = childConv.id

        jobs.append(job)
        saveToDisk()
        pumpSubAgentQueue(for: parentID)

        if !wait {
            return ToolResult(output: jsonString([
                "ok": true,
                "status": job.state.rawValue,
                "job_id": job.id,
                "child_session_id": childConv.id.uuidString,
                "agent": subAgentDef.name,
                "model_origin": resolved.origin.rawValue,
                "model_resolved": resolved.label,
                "model_group_unavailable": resolved.groupUnavailable,
                "max_minutes": maxMinutes,
            ]))
        }

        // wait=true: suspend until job finishes OR parent task is cancelled (e.g., user sent a message or clicked Stop).
        while !job.state.isTerminal {
            if Task.isCancelled {
                // Move to background delivery so when it finishes it posts a callback to the parent conversation!
                job.deliverToParentOnFinish = true
                saveToDisk()
                return ToolResult(output: jsonString([
                    "ok": true,
                    "status": "running",
                    "note": "Parent turn was interrupted while waiting; sub-agent moved to background and will post its result when done.",
                    "job_id": job.id,
                    "child_session_id": childConv.id.uuidString,
                    "agent": subAgentDef.name,
                ]))
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return ToolResult(output: jsonString(buildSubAgentResultPayload(job)), isError: job.state == .failed || job.state == .timeout)
    }

    private func resolveModelForSubAgent(def: SubAgentDefinition, parentID: UUID, choice: SubAgentModelChoice, store: AppStore)
        -> (groupID: UUID?, origin: HelperModelOrigin, label: String, groupUnavailable: Bool) {
        func groupRouteLabel(_ g: ModelGroup) -> String? {
            guard let eid = ModelRouter.candidates(group: g, sessionKey: parentID.uuidString, isAvailable: { store.isAvailable($0) }).first,
                  let e = store.entry(eid) else { return nil }
            return store.entryLabel(e)
        }

        let parentGroup = store.group(for: parentID)
        let parentLabel = parentGroup.flatMap(groupRouteLabel) ?? (parentGroup?.name ?? "Default")

        if let pinnedID = def.modelGroupID {
            if let g = store.settings.groups.first(where: { $0.id == pinnedID }), let lbl = groupRouteLabel(g) {
                return (g.id, .pinned, lbl, false)
            }
            return (parentGroup?.id, .inherited, parentLabel, true)
        }

        switch choice {
        case .sameAsParent:
            return (parentGroup?.id, .inherited, parentLabel, false)
        case .defaultModel:
            if let gid = store.settings.activeGroupID,
               let g = store.settings.groups.first(where: { $0.id == gid }),
               let lbl = groupRouteLabel(g) {
                return (g.id, .defaultGroup, lbl, false)
            }
            return (parentGroup?.id, .inherited, parentLabel, false)
        case .subModel:
            if let gid = store.settings.subGroupID,
               let g = store.settings.groups.first(where: { $0.id == gid }),
               let lbl = groupRouteLabel(g) {
                return (g.id, .subGroup, lbl, false)
            }
            return (parentGroup?.id, .inherited, parentLabel, false)
        }
    }

    // MARK: - Sub-Agent Queue Pump, Execution & Actions

    func pumpSubAgentQueue(for parentID: UUID) {
        while canStartChildJob(for: parentID) {
            guard let next = jobs.first(where: {
                $0.isSubAgentJob && $0.target.parentConversationID == parentID && $0.state == .queued
            }) else { break }
            startSubAgentRun(next)
        }
        syncKeepAliveCounts()
    }

    private func startSubAgentRun(_ job: AgentJob) {
        guard let store, let childID = job.runConversationID else {
            finishSubAgentRun(job, state: .failed, result: "Child conversation missing.")
            return
        }
        job.state = .running
        job.startedAt = Date()
        job.endedAt = nil
        saveToDisk()

        // Wall-clock timeout task
        let budgetSeconds = UInt64(max(1, job.maxMinutes)) * 60
        job.timeoutTask?.cancel()
        job.timeoutTask = Task { [weak self, weak job] in
            try? await Task.sleep(nanoseconds: budgetSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, let job, job.state == .running else { return }
            store.stop(childID)
            let partial = self.latestChildAnswer(in: childID)
            self.finishSubAgentRun(
                job,
                state: .timeout,
                result: partial.isEmpty ? "(Sub-agent timed out after \(job.maxMinutes)m with no text output.)" : partial
            )
        }

        // Optional mid-run progress report loop (`frequent` = 15s, `moderate` = 60s)
        job.progressTask?.cancel()
        if let interval = job.progressCadence.intervalSeconds, let parentID = job.target.parentConversationID {
            job.progressTask = Task { [weak self, weak job] in
                var lastSnapshot = ""
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard !Task.isCancelled, let self, let job, job.state == .running else { return }
                    let latest = self.latestChildAnswer(in: childID)
                    let snap = "\(job.turnsCount)|\(job.currentTool)|\(latest.suffix(160))"
                    guard snap != lastSnapshot else { continue }
                    lastSnapshot = snap
                    let cb = AgentCallback(
                        kind: .progress,
                        jobId: job.id,
                        childSessionId: childID.uuidString,
                        title: job.title,
                        status: "running",
                        modelOrigin: job.modelOrigin,
                        modelResolved: job.modelResolvedLabel,
                        agent: job.subAgentName,
                        elapsed: ScheduleParser.formatElapsed(job.elapsedSeconds),
                        tool: job.currentTool.isEmpty ? nil : job.currentTool,
                        activity: job.currentTool.isEmpty ? "thinking" : "running tool \(job.currentTool)",
                        turn: job.turnsCount,
                        summary: job.summaryString,
                        body: latest.isEmpty ? "(working…)" : String(latest.suffix(600)),
                        siblings: self.siblingStatusLine(for: parentID, excluding: job.id)
                    )
                    store.deliverProgrammaticTurn(cb.xml, to: parentID)
                }
            }
        }

        // Launch the child session's agent loop
        job.task?.cancel()
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            await store.runChildSubAgent(job: job, childConversationID: childID)
        }
    }

    func latestChildAnswer(in childID: UUID) -> String {
        guard let c = store?.conversation(childID) else { return "" }
        for m in c.messages.reversed() where m.role == .assistant && !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return m.content
        }
        return ""
    }

    func finishSubAgentRun(_ job: AgentJob, state: AgentJobState, result: String) {
        guard !job.state.isTerminal else { return }
        job.timeoutTask?.cancel()
        job.timeoutTask = nil
        job.progressTask?.cancel()
        job.progressTask = nil
        job.task?.cancel()
        job.task = nil

        if !job.pendingSteers.isEmpty {
            job.missedSteers.append(contentsOf: job.pendingSteers)
            job.pendingSteers.removeAll()
        }
        job.state = state
        job.endedAt = Date()
        job.currentTool = ""
        job.resultText = result
        saveToDisk()

        NotificationCenter.default.post(name: .agentJobDidFinish, object: job.id)

        if let parentID = job.target.parentConversationID {
            pumpSubAgentQueue(for: parentID)
            if job.deliverToParentOnFinish, let store {
                var body = result
                if !job.missedSteers.isEmpty {
                    body += "\n\n[Note: \(job.missedSteers.count) steer message(s) arrived after the sub-agent finished and were not applied.]"
                }
                let cb = AgentCallback(
                    kind: .finished,
                    jobId: job.id,
                    childSessionId: job.runConversationID?.uuidString,
                    title: job.title,
                    status: state.rawValue,
                    modelOrigin: job.modelOrigin,
                    modelResolved: job.modelResolvedLabel,
                    agent: job.subAgentName,
                    elapsed: ScheduleParser.formatElapsed(job.elapsedSeconds),
                    tool: nil,
                    activity: nil,
                    turn: job.turnsCount,
                    summary: job.summaryString,
                    body: body,
                    siblings: siblingStatusLine(for: parentID, excluding: job.id)
                )
                store.deliverProgrammaticTurn(cb.xml, to: parentID)
                BackgroundKeepAliveManager.shared.notifyCompletionIfNeeded(
                    title: "子代理已完成：\(job.title)",
                    body: result
                )
            }
        }
    }

    func buildSubAgentResultPayload(_ job: AgentJob) -> [String: Any] {
        var out: [String: Any] = [
            "ok": job.state == .done,
            "status": job.state.rawValue,
            "job_id": job.id,
            "child_session_id": job.runConversationID?.uuidString ?? "",
            "agent": job.subAgentName ?? SubAgentDefinition.builtInName,
            "model_origin": job.modelOrigin ?? "inherited",
            "model_resolved": job.modelResolvedLabel ?? "",
            "model_group_unavailable": job.modelGroupUnavailable,
            "elapsed_s": Int(job.elapsedSeconds.rounded()),
            "turns": job.turnsCount,
            "summary": job.summaryString,
            "result": job.resultText ?? "",
        ]
        if job.wasResumed { out["resumed"] = true }
        if !job.missedSteers.isEmpty { out["missed_steers"] = job.missedSteers }
        return out
    }

    // MARK: - status / steer / cancel / resume

    private func statusSubAgents(args: [String: Any], parentID: UUID) -> ToolResult {
        if let rawID = args["job_id"] as? String, !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let job = job(matchingPrefix: rawID, in: parentID), job.isSubAgentJob else {
                return ToolResult(output: "Error: no sub-agent matching job_id '\(rawID)' in this conversation.", isError: true)
            }
            return ToolResult(output: jsonString(buildSubAgentResultPayload(job)))
        }
        let list = subAgentJobs(for: parentID).map { j -> [String: Any] in
            var d = buildSubAgentResultPayload(j)
            if !j.currentTool.isEmpty { d["current_tool"] = j.currentTool }
            return d
        }
        return ToolResult(output: jsonString([
            "ok": true,
            "count": list.count,
            "sub_agents": list,
        ]))
    }

    private func steerSubAgent(args: [String: Any], parentID: UUID) -> ToolResult {
        guard let rawID = (args["job_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty else {
            return ToolResult(output: "Error: action=steer requires 'job_id'.", isError: true)
        }
        guard let msg = (args["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty else {
            return ToolResult(output: "Error: action=steer requires a non-empty 'message'.", isError: true)
        }
        guard let job = job(matchingPrefix: rawID, in: parentID), job.isSubAgentJob else {
            return ToolResult(output: "Error: no sub-agent matching job_id '\(rawID)' in this conversation.", isError: true)
        }
        guard job.state == .running || job.state == .queued else {
            job.missedSteers.append(msg)
            saveToDisk()
            return ToolResult(output: jsonString([
                "ok": false,
                "job_id": job.id,
                "status": job.state.rawValue,
                "steer": "missed — sub-agent already finished with state \(job.state.rawValue)",
            ]))
        }
        job.pendingSteers.append(msg)
        saveToDisk()
        return ToolResult(output: jsonString([
            "ok": true,
            "job_id": job.id,
            "status": job.state.rawValue,
            "steer": "queued — will be injected on the sub-agent's next turn",
            "pending_steers": job.pendingSteers.count,
        ]))
    }

    private func cancelSubAgent(args: [String: Any], parentID: UUID) async -> ToolResult {
        guard let rawID = (args["job_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty else {
            return ToolResult(output: "Error: action=cancel requires 'job_id'.", isError: true)
        }
        guard let job = job(matchingPrefix: rawID, in: parentID), job.isSubAgentJob else {
            return ToolResult(output: "Error: no sub-agent matching job_id '\(rawID)' in this conversation.", isError: true)
        }
        cancel(jobId: job.id, reason: "cancelled by parent agent")
        return ToolResult(output: jsonString(buildSubAgentResultPayload(job)))
    }

    private func resumeSubAgents(args: [String: Any], parentID: UUID) async -> ToolResult {
        let rawJob = (args["job_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSession = (args["child_session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = subAgentJobs(for: parentID).filter { j in
            guard j.state == .interrupted else { return false }
            if let rawJob, !rawJob.isEmpty {
                return j.id.uppercased().hasPrefix(rawJob.uppercased())
            }
            if let rawSession, !rawSession.isEmpty {
                return j.runConversationID?.uuidString.uppercased().hasPrefix(rawSession.uppercased()) == true
            }
            return true
        }
        guard !candidates.isEmpty else {
            return ToolResult(output: jsonString([
                "ok": true,
                "resumed_count": 0,
                "note": "No interrupted sub-agents found to resume in this conversation.",
            ]))
        }
        var resumedIDs: [String] = []
        for j in candidates {
            j.wasResumed = true
            j.state = .queued
            j.endedAt = nil
            resumedIDs.append(j.id)
        }
        saveToDisk()
        pumpSubAgentQueue(for: parentID)
        return ToolResult(output: jsonString([
            "ok": true,
            "resumed_count": resumedIDs.count,
            "resumed_job_ids": resumedIDs,
        ]))
    }

    func cancel(jobId: String, reason: String = "cancelled") {
        guard let job = jobs.first(where: { $0.id == jobId || $0.id.hasPrefix(jobId.uppercased()) }) else { return }
        if job.isSubAgentJob {
            if let cid = job.runConversationID { store?.stop(cid) }
            let partial = job.runConversationID.map(latestChildAnswer) ?? ""
            finishSubAgentRun(
                job,
                state: .cancelled,
                result: partial.isEmpty ? "(Sub-agent cancelled: \(reason))" : partial + "\n\n[Cancelled: \(reason)]"
            )
        } else {
            job.task?.cancel()
            job.task = nil
            job.state = .cancelled
            job.endedAt = Date()
            saveToDisk()
        }
    }

    func cancelAll(forConversation conversationID: UUID) {
        for j in jobs where !j.state.isTerminal {
            if j.target.parentConversationID == conversationID || j.creatorConversationID == conversationID {
                cancel(jobId: j.id, reason: "parent conversation stopped or deleted")
            }
        }
    }

    // MARK: - Scheduled Tasks (`scheduled_task` tool & UI)

    func runScheduledTaskTool(args: [String: Any], callerConversationID: UUID?) async -> ToolResult {
        let action = (args["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "list"
        switch action {
        case "create":
            return createScheduledJob(args: args, callerID: callerConversationID)
        case "list":
            return listScheduledJobs(callerID: callerConversationID)
        case "delete", "cancel":
            guard let id = (args["id"] as? String) ?? (args["job_id"] as? String), !id.isEmpty else {
                return ToolResult(output: "Error: scheduled_task action=\(action) requires 'id'.", isError: true)
            }
            deleteJob(id: id)
            return ToolResult(output: jsonString(["ok": true, "deleted_id": id]))
        case "enable":
            guard let id = (args["id"] as? String) ?? (args["job_id"] as? String), !id.isEmpty else {
                return ToolResult(output: "Error: scheduled_task action=enable requires 'id'.", isError: true)
            }
            setScheduledJobEnabled(id: id, enabled: true)
            return ToolResult(output: jsonString(["ok": true, "id": id, "enabled": true]))
        case "disable":
            guard let id = (args["id"] as? String) ?? (args["job_id"] as? String), !id.isEmpty else {
                return ToolResult(output: "Error: scheduled_task action=disable requires 'id'.", isError: true)
            }
            setScheduledJobEnabled(id: id, enabled: false)
            return ToolResult(output: jsonString(["ok": true, "id": id, "enabled": false]))
        case "run":
            guard let id = (args["id"] as? String) ?? (args["job_id"] as? String),
                  let job = job(matchingPrefix: id) else {
                return ToolResult(output: "Error: scheduled job not found.", isError: true)
            }
            let firedID = await fireScheduledJob(job, claimed: false)
            return ToolResult(output: jsonString([
                "ok": firedID != nil,
                "id": job.id,
                "fired": firedID != nil,
                "session_id": firedID?.uuidString ?? "",
            ]))
        case "skip_next":
            guard let id = (args["id"] as? String) ?? (args["job_id"] as? String),
                  let job = job(matchingPrefix: id) else {
                return ToolResult(output: "Error: scheduled job not found.", isError: true)
            }
            skipNextScheduledRun(job)
            return ToolResult(output: jsonString([
                "ok": true,
                "id": job.id,
                "state": job.state.rawValue,
                "next_fire_at": job.nextFireAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            ]))
        default:
            return ToolResult(output: "Error: unknown scheduled_task action '\(action)'. Valid actions: create, list, delete, enable, disable, run, skip_next.", isError: true)
        }
    }

    private func createScheduledJob(args: [String: Any], callerID: UUID?) -> ToolResult {
        let prompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            return ToolResult(output: "Error: scheduled_task action=create requires a non-empty 'prompt'.", isError: true)
        }
        let label = (args["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (label?.isEmpty == false ? label! : String(prompt.prefix(32)))

        // Parse trigger: after (once) | interval (+ count) (loop) | time (+ repeat/days) (cron) | of_job_id (onCompletion)
        let trigger: AgentJobTrigger
        var initialRemaining: Int? = nil

        if let afterRaw = args["after"] as? String, let secs = ScheduleParser.parseDuration(afterRaw) {
            trigger = .once(after: max(1, secs))
        } else if let intervalRaw = args["interval"] as? String, let secs = ScheduleParser.parseDuration(intervalRaw) {
            let count = (args["count"] as? Int) ?? (args["count"] as? String).flatMap(Int.init)
            if let count, count > 0 { initialRemaining = count }
            trigger = .loop(interval: max(5, secs), count: initialRemaining)
        } else if let timeRaw = args["time"] as? String, let hm = ScheduleParser.parseTimeOfDay(timeRaw) {
            let days = ScheduleParser.parseWeekdays(repeatMode: args["repeat"] as? String, daysRaw: args["days"] as? String) ?? Set(1...7)
            trigger = .cron(hour: hm.hour, minute: hm.minute, days: days, start: nil, end: nil)
        } else if let ofJob = (args["of"] as? String) ?? (args["of_job_id"] as? String),
                  !ofJob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trigger = .onCompletion(ofJobId: ofJob.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        } else {
            return ToolResult(output: "Error: scheduled_task create requires one trigger: 'after' (e.g. '30m'), 'interval' (e.g. '10m'), 'time' (e.g. '09:00'), or 'of' (job_id).", isError: true)
        }

        // Parse preset shell command if provided
        let cmdTimeout = (args["command_timeout"] as? Double) ?? ScheduleParser.parseDuration(args["command_timeout"] as? String)
        let presetResult = ScheduledPresetToolCall.parse(
            command: args["command"] as? String,
            timeoutSeconds: cmdTimeout,
            toolArgsJSON: args["tool_args"] as? String
        )
        let preset: ScheduledPresetToolCall?
        switch presetResult {
        case .success(let p): preset = p
        case .failure(let msg): return ToolResult(output: "Error: \(msg)", isError: true)
        }

        // Resolve target (`follow-up` default when inside a conversation, else `new`)
        let explicitTarget = args["target"] as? String
        let explicitSession = args["session_id"] as? String
        let (targetKind, defaulted) = ScheduledTargetDelivery.resolveTarget(
            explicit: explicitTarget,
            session: explicitSession,
            callerSession: callerID?.uuidString
        )
        let targetSessionID = explicitSession.flatMap(UUID.init(uuidString:)) ?? callerID

        let target: AgentJobTarget
        let destination: ScheduledTargetDelivery.Destination
        switch targetKind {
        case "new":
            target = .new
            destination = .newChat(label: label)
        case "child-of-current", "child_of_current", "child":
            guard let pid = targetSessionID else {
                return ToolResult(output: "Error: target=child-of-current requires an active conversation.", isError: true)
            }
            target = .childOfCurrent(parentConversationID: pid, parentToolUseID: nil)
            destination = .childOfCurrent(parentSessionId: pid.uuidString, isCallerSession: pid == callerID)
        default:
            guard let sid = targetSessionID else {
                target = .new
                destination = .newChat(label: label)
                break
            }
            target = .followUp(conversationID: sid)
            let sTitle = store?.conversation(sid)?.title
            destination = .followUp(sessionId: sid.uuidString, title: sTitle, isCallerSession: sid == callerID)
        }

        let job = AgentJob(
            label: label,
            origin: .tool,
            trigger: trigger,
            target: target,
            prompt: prompt,
            title: title,
            state: .pending
        )
        job.remaining = initialRemaining
        job.presetToolCall = preset
        job.creatorConversationID = callerID
        if let th = args["thinking"] as? String {
            job.thinkingLevel = ThinkingLevel(rawValue: th.lowercased())
        }

        jobs.append(job)
        armScheduledJob(job)
        saveToDisk()

        let iso = ISO8601DateFormatter()
        let deliveryLine = ScheduledTargetDelivery.sentence(destination, defaulted: defaulted)
        var out: [String: Any] = [
            "ok": true,
            "id": job.id,
            "title": job.title,
            "trigger": job.trigger.logLabel,
            "target": destination.kind,
            "delivery": deliveryLine,
            "next_fire_at": job.nextFireAt.map { iso.string(from: $0) } ?? "event",
        ]
        if let preset { out["preset_command"] = preset.command }
        return ToolResult(output: jsonString(out))
    }

    private func listScheduledJobs(callerID: UUID?) -> ToolResult {
        let iso = ISO8601DateFormatter()
        let list = jobs.filter { $0.isScheduledTimer }.map { j -> [String: Any] in
            var d: [String: Any] = [
                "id": j.id,
                "title": j.title,
                "trigger": j.trigger.logLabel,
                "state": j.state.rawValue,
                "enabled": j.isEnabled,
                "fired_count": j.firedCount,
                "next_fire_at": j.nextFireAt.map { iso.string(from: $0) } ?? "",
                "prompt": j.prompt ?? "",
            ]
            if let r = j.remaining { d["remaining"] = r }
            if let p = j.presetToolCall { d["preset_command"] = p.command }
            return d
        }
        return ToolResult(output: jsonString([
            "ok": true,
            "count": list.count,
            "scheduled_tasks": list,
        ]))
    }

    func deleteJob(id: String) {
        if let j = job(matchingPrefix: id) {
            j.task?.cancel()
            j.timeoutTask?.cancel()
            j.progressTask?.cancel()
            jobs.removeAll { $0.id == j.id }
            saveToDisk()
        }
    }

    func setScheduledJobEnabled(id: String, enabled: Bool) {
        guard let j = job(matchingPrefix: id), j.isScheduledTimer else { return }
        j.isEnabled = enabled
        if enabled && j.state == .pending {
            armScheduledJob(j)
        } else {
            j.task?.cancel()
            j.task = nil
            j.nextFireAt = nil
        }
        saveToDisk()
    }

    // MARK: - Arm, Fire, Skip & Run Now (ScheduledJobRunner.swift)

    func armScheduledJob(_ job: AgentJob, firstFireAt: Date? = nil) {
        job.task?.cancel()
        job.task = nil
        guard job.isEnabled, job.state == .pending else {
            syncKeepAliveCounts()
            return
        }

        switch job.trigger {
        case .immediate:
            job.nextFireAt = Date()
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                _ = await self.fireScheduledJob(job, claimed: false)
                self.finishScheduledJobIfExhausted(job)
            }

        case .once(let after):
            let targetDate: Date
            if let existing = firstFireAt ?? job.nextFireAt, existing > Date() {
                targetDate = existing
            } else {
                targetDate = Date().addingTimeInterval(after)
            }
            job.nextFireAt = targetDate
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                guard await Self.sleepUntil(targetDate) else { return }
                _ = await self.fireScheduledJob(job, claimed: false)
                self.finishScheduledJob(job, state: .done)
            }

        case .loop(let interval, _):
            let first: Date
            if let f = firstFireAt {
                first = f
            } else if let existing = job.nextFireAt, existing > Date() {
                first = existing
            } else {
                first = Date().addingTimeInterval(interval)
            }
            job.nextFireAt = first
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                var next = first
                while !Task.isCancelled {
                    guard await Self.sleepUntil(next) else { return }
                    _ = await self.fireScheduledJob(job, claimed: false)
                    if Task.isCancelled || !job.isEnabled || job.state != .pending { return }
                    if let r = job.remaining, r <= 0 {
                        self.finishScheduledJob(job, state: .done)
                        return
                    }
                    next = Date().addingTimeInterval(interval)
                    job.nextFireAt = next
                    self.saveToDisk()
                }
            }

        case .cron(let hour, let minute, let days, let start, let end):
            guard let first = firstFireAt ?? ScheduleParser.nextCronDate(
                hour: hour, minute: minute, days: days, start: start, end: end, from: Date()
            ) else {
                finishScheduledJob(job, state: .done)
                return
            }
            job.nextFireAt = first
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                var next = first
                while !Task.isCancelled {
                    guard await Self.sleepUntil(next) else { return }
                    _ = await self.fireScheduledJob(job, claimed: false)
                    if Task.isCancelled || !job.isEnabled || job.state != .pending { return }
                    guard let following = ScheduleParser.nextCronDate(
                        hour: hour, minute: minute, days: days, start: start, end: end,
                        from: max(Date(), next.addingTimeInterval(60))
                    ) else {
                        self.finishScheduledJob(job, state: .done)
                        return
                    }
                    next = following
                    job.nextFireAt = following
                    self.saveToDisk()
                }
            }

        case .onCompletion(let ofJobId):
            job.nextFireAt = nil
            job.task = Task { [weak self, weak job] in
                let seq = NotificationCenter.default.notifications(named: .agentJobDidFinish)
                for await note in seq {
                    if Task.isCancelled { return }
                    if let doneId = note.object as? String,
                       doneId == ofJobId || doneId.hasPrefix(ofJobId) {
                        break
                    }
                }
                guard !Task.isCancelled, let self, let job, job.isEnabled, job.state == .pending else { return }
                _ = await self.fireScheduledJob(job, upstreamJobID: ofJobId, claimed: false)
                self.finishScheduledJob(job, state: .done)
            }
        }
        syncKeepAliveCounts()
    }

    private static func sleepUntil(_ target: Date) async -> Bool {
        while !Task.isCancelled {
            let diff = target.timeIntervalSinceNow
            if diff <= 0 { return true }
            let step = min(diff, 30.0)
            do {
                try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            } catch {
                return false
            }
        }
        return false
    }

    func skipNextScheduledRun(_ job: AgentJob) {
        guard job.isEnabled, job.state == .pending else { return }
        switch job.trigger {
        case .loop(let interval, _):
            if let r = job.remaining {
                if r <= 1 {
                    cancel(jobId: job.id, reason: "user skipped its last run")
                    return
                }
                job.remaining = r - 1
            }
            job.skippedCount += 1
            let base = job.nextFireAt ?? Date()
            armScheduledJob(job, firstFireAt: base.addingTimeInterval(interval))
            saveToDisk()
        case .cron(let h, let m, let days, let s, let e):
            let base = (job.nextFireAt ?? Date()).addingTimeInterval(60)
            guard let next = ScheduleParser.nextCronDate(hour: h, minute: m, days: days, start: s, end: e, from: base) else {
                cancel(jobId: job.id, reason: "user skipped its last run")
                return
            }
            job.skippedCount += 1
            armScheduledJob(job, firstFireAt: next)
            saveToDisk()
        case .once, .onCompletion, .immediate:
            cancel(jobId: job.id, reason: "user skipped its only run")
        }
    }

    func runNowScheduledJob(_ job: AgentJob) {
        guard !job.fireInFlight else { return }
        Task { [weak self, weak job] in
            guard let self, let job else { return }
            _ = await self.fireScheduledJob(job, claimed: false)
        }
    }

    @discardableResult
    func fireScheduledJob(_ job: AgentJob, upstreamJobID: String? = nil, claimed: Bool = false) async -> UUID? {
        guard let store else { return nil }
        if !claimed {
            guard !job.fireInFlight else { return nil }
            job.fireInFlight = true
        }
        defer { job.fireInFlight = false }

        var prompt = job.prompt ?? ""
        if let upID = upstreamJobID, let up = self.job(matchingPrefix: upID) {
            prompt = prompt.replacingOccurrences(of: "{{result}}", with: up.resultText ?? "")
        }

        let envelope = buildScheduledEnvelope(job, prompt: prompt)
        job.firedCount += 1
        if let r = job.remaining {
            job.remaining = max(0, r - 1)
        }
        saveToDisk()

        switch job.target {
        case .new:
            var c = Conversation()
            c.title = job.label.map { "Scheduled · \($0)" } ?? "Scheduled · \(job.title)"
            c.thinkingLevel = job.thinkingLevel
            store.conversations.insert(c, at: 0)
            store.selectedID = c.id
            store.saveConversations()
            store.deliverProgrammaticTurn(envelope, to: c.id, preset: job.presetToolCall, presetTitle: job.title)
            BackgroundKeepAliveManager.shared.notifyCompletionIfNeeded(title: "定时任务已触发：\(job.title)", body: prompt)
            return c.id

        case .followUp(let cid):
            guard store.conversation(cid) != nil else { return nil }
            if let th = job.thinkingLevel { store.setThinking(th, for: cid) }
            store.deliverProgrammaticTurn(envelope, to: cid, preset: job.presetToolCall, presetTitle: job.title)
            BackgroundKeepAliveManager.shared.notifyCompletionIfNeeded(title: "定时任务已触发：\(job.title)", body: prompt)
            return cid

        case .rerun(let cid, let mid):
            guard store.conversation(cid) != nil else { return nil }
            store.regenerate(mid, in: cid)
            return cid

        case .childOfCurrent(let parentID, _):
            guard store.conversation(parentID) != nil else { return nil }
            _ = await delegateSubAgent(
                args: [
                    "tool_title": job.title,
                    "task": prompt,
                    "wait": false,
                ],
                parentID: parentID,
                toolUseID: "sched_\(job.id.prefix(8))"
            )
            return parentID
        }
    }

    private func finishScheduledJob(_ job: AgentJob, state: AgentJobState) {
        job.task?.cancel()
        job.task = nil
        job.state = state
        job.nextFireAt = nil
        job.endedAt = Date()
        saveToDisk()
    }

    private func finishScheduledJobIfExhausted(_ job: AgentJob) {
        if job.state == .pending {
            finishScheduledJob(job, state: .done)
        }
    }

    private func roundPrefix(_ job: AgentJob) -> String {
        let nextFireNum = job.firedCount + 1
        switch job.trigger {
        case .loop(_, let count):
            if let r = job.remaining {
                let remAfter = max(0, r - 1)
                return "[Scheduled task \"\(job.title)\" · fire \(nextFireNum) · remaining \(remAfter) · \(job.trigger.logLabel)]\n"
            }
            let totalStr = count.map { "/\($0)" } ?? ""
            return "[Scheduled task \"\(job.title)\" · round \(nextFireNum)\(totalStr) · \(job.trigger.logLabel)]\n"
        case .cron:
            return "[Scheduled task \"\(job.title)\" · fire \(nextFireNum) · \(job.trigger.logLabel)]\n"
        case .once, .immediate, .onCompletion:
            return "[Scheduled task \"\(job.title)\" · \(job.trigger.logLabel)]\n"
        }
    }

    func buildScheduledEnvelope(_ job: AgentJob, prompt: String) -> String {
        var fireIdx: Int? = nil
        var remAfter: Int? = nil
        switch job.trigger {
        case .loop, .cron:
            fireIdx = job.firedCount + 1
            remAfter = job.remaining.map { max(0, $0 - 1) }
        default:
            break
        }
        let iso = ISO8601DateFormatter()
        let nextFire: Date? = {
            switch job.trigger {
            case .loop(let interval, _):
                if let r = job.remaining, r - 1 <= 0 { return nil }
                return Date().addingTimeInterval(interval)
            case .cron(let h, let m, let days, let s, let e):
                return ScheduleParser.nextCronDate(hour: h, minute: m, days: days, start: s, end: e, from: Date().addingTimeInterval(60))
            case .once, .immediate, .onCompletion:
                return nil
            }
        }()
        let cb = AgentCallback(
            kind: .scheduled,
            jobId: job.id,
            childSessionId: nil,
            title: job.label ?? job.title,
            status: "running",
            modelOrigin: nil,
            modelResolved: nil,
            agent: nil,
            elapsed: nil,
            tool: nil,
            activity: nil,
            turn: nil,
            summary: nil,
            body: roundPrefix(job) + (job.presetToolCall?.envelopeNote ?? "") + prompt,
            siblings: nil,
            fireIndex: fireIdx,
            remaining: remAfter,
            triggerLabel: job.trigger.logLabel,
            nextFireAt: nextFire.map { iso.string(from: $0) }
        )
        return cb.xml
    }
}
