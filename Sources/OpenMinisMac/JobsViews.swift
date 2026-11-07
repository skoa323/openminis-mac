import SwiftUI
import AppKit

// UI components for Round 6: AgentCallback cards in chat, Active Jobs Banner,
// Child Sub-Agent Transcript Sheet, SubAgentsSettings, ScheduledAndBackgroundSettings, and MenuBarJobsView.

// MARK: - Agent Callback Card in Chat (AgentCallbackCellView port)

struct AgentCallbackCardView: View {
    @EnvironmentObject var store: AppStore
    let callback: AgentCallback
    @State private var expanded: Bool = false
    @State private var inspectSessionID: UUID? = nil

    private var iconName: String {
        switch callback.kind {
        case .finished: return "person.2.badge.gearshape"
        case .progress: return "clock.arrow.2.circlepath"
        case .scheduled: return "calendar.badge.clock"
        }
    }

    private var accent: Color {
        switch callback.kind {
        case .scheduled: return .purple
        case .progress: return .blue
        case .finished:
            switch callback.status {
            case "done": return .green
            case "cancelled": return .orange
            case "failed", "timeout": return .red
            default: return .accentColor
            }
        }
    }

    private var headerLabel: String {
        switch callback.kind {
        case .finished: return "子代理已完成"
        case .progress: return "子代理进度汇报"
        case .scheduled: return "定时任务触发"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(accent)
                Text(headerLabel)
                    .font(.caption.bold())
                    .foregroundStyle(accent)
                Text(callback.title)
                    .font(.callout.bold())
                    .lineLimit(1)

                if let agent = callback.agent, !agent.isEmpty {
                    Text(agent)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.14))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 8)

                if let fire = callback.fireIndex {
                    let remText = callback.remaining.map { " · 剩余 \($0) 次" } ?? ""
                    Text("第 \(fire) 次\(remText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let elapsed = callback.elapsed {
                    Text(elapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(callback.status)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.15))
                    .foregroundStyle(accent)
                    .clipShape(Capsule())

                if let sidStr = callback.childSessionId, let uid = UUID(uuidString: sidStr),
                   store.conversation(uid) != nil {
                    Button("查看过程") { inspectSessionID = uid }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            if let summary = callback.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let trig = callback.triggerLabel, callback.kind == .scheduled {
                HStack(spacing: 8) {
                    Text("触发器：\(trig)")
                    if let next = callback.nextFireAt, !next.isEmpty {
                        Text("下次：\(next)")
                    } else {
                        Text("本次为最后一次触发")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let sib = callback.siblings, !sib.isEmpty {
                Text(sib)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if expanded {
                Divider()
                MarkdownText(text: callback.body)
                    .padding(.top, 2)
            } else if !callback.body.isEmpty {
                Text(callback.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(accent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.28), lineWidth: 1))
        .sheet(item: Binding(
            get: { inspectSessionID.map(UUIDIdentifiable.init) },
            set: { inspectSessionID = $0?.id }
        )) { item in
            SubAgentTranscriptSheet(conversationID: item.id)
                .environmentObject(store)
        }
    }
}

struct UUIDIdentifiable: Identifiable {
    let id: UUID
}

// MARK: - Active Jobs & Timers Banner in Chat

struct ActiveJobsBanner: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var registry = AgentJobRegistry.shared
    let conversationID: UUID
    @State private var inspectSessionID: UUID? = nil

    private var activeSubAgents: [AgentJob] {
        registry.subAgentJobs(for: conversationID).filter { $0.state == .running || $0.state == .queued }
    }

    private var activeTimers: [AgentJob] {
        registry.scheduledJobs(for: conversationID)
    }

    var body: some View {
        let subs = activeSubAgents
        let timers = activeTimers
        if !subs.isEmpty || !timers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(subs) { job in
                        SubAgentPill(job: job, onInspect: {
                            if let cid = job.runConversationID { inspectSessionID = cid }
                        })
                    }
                    ForEach(timers) { job in
                        ScheduledTimerPill(job: job)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .background(Color.secondary.opacity(0.06))
            .sheet(item: Binding(
                get: { inspectSessionID.map(UUIDIdentifiable.init) },
                set: { inspectSessionID = $0?.id }
            )) { item in
                SubAgentTranscriptSheet(conversationID: item.id)
                    .environmentObject(store)
            }
        }
    }
}

private struct SubAgentPill: View {
    @ObservedObject var job: AgentJob
    let onInspect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(job.title)
                .font(.caption.bold())
                .lineLimit(1)
            if job.state == .queued {
                Text("排队中")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if !job.currentTool.isEmpty {
                Text(job.currentTool)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("查看", action: onInspect)
                .buttonStyle(.borderless)
                .font(.caption2)
            Button {
                AgentJobRegistry.shared.cancel(jobId: job.id, reason: "user stopped from toolbar")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("停止该子代理")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct ScheduledTimerPill: View {
    @ObservedObject var job: AgentJob

    var body: some View {
        Menu {
            Text("触发器：\(job.trigger.logLabel)")
            if let next = job.nextFireAt {
                Text("下次触发：\(SessionExport.stamp.string(from: next))")
            }
            Divider()
            Button("立即运行一次") {
                AgentJobRegistry.shared.runNowScheduledJob(job)
            }
            .disabled(!job.isEnabled || job.fireInFlight)
            Button("跳过下一次触发") {
                AgentJobRegistry.shared.skipNextScheduledRun(job)
            }
            .disabled(!job.isEnabled)
            Button(job.isEnabled ? "暂停定时任务" : "恢复定时任务") {
                AgentJobRegistry.shared.setScheduledJobEnabled(id: job.id, enabled: !job.isEnabled)
            }
            Divider()
            Button("取消并删除", role: .destructive) {
                AgentJobRegistry.shared.deleteJob(id: job.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: job.isEnabled ? "timer" : "pause.circle")
                    .foregroundStyle(job.isEnabled ? Color.purple : Color.secondary)
                Text(job.title)
                    .font(.caption.bold())
                    .lineLimit(1)
                if let r = job.remaining {
                    Text("剩余\(r)次")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.purple.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Child Sub-Agent Transcript Sheet

struct SubAgentTranscriptSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID

    var body: some View {
        let conv = store.conversation(conversationID)
        let messages = conv?.messages ?? []
        let results: [String: ChatMessage] = {
            var d: [String: ChatMessage] = [:]
            for m in messages where m.role == .tool {
                if let k = m.toolCallId { d[k] = m }
            }
            return d
        }()
        let visible = messages.filter { $0.role == .user || ($0.role == .assistant && !($0.content.isEmpty && $0.toolCalls.isEmpty && $0.reasoning.isEmpty)) }

        VStack(spacing: 0) {
            HStack {
                Image(systemName: "person.2.badge.gearshape")
                    .foregroundStyle(Color.accentColor)
                Text(conv?.title ?? "子代理执行记录")
                    .font(.headline)
                if store.isRunning(conversationID) {
                    ProgressView().controlSize(.small)
                    Text("运行中…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(visible) { m in
                        MessageRow(message: m, results: results, conversationID: conversationID, streaming: store.isRunning(conversationID))
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 500, idealHeight: 620)
    }
}

// MARK: - SubAgentsSettings Tab (in SettingsView)

struct SubAgentsSettings: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var subStore = SubAgentStore.shared
    @State private var selection: String = SubAgentDefinition.builtInId
    @State private var draft = SubAgentDefinition.makeBuiltIn()
    @State private var errorMessage: String? = nil

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Array(subStore.subAgents.enumerated()), id: \.element.id) { idx, def in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(def.displayName)
                                    .lineLimit(1)
                                Text(def.isBuiltIn ? "内置 · 不可删除" : (def.modelGroupID == nil ? "Auto" : "固定分组"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !def.isBuiltIn {
                                Button {
                                    subStore.moveCustom(at: idx, delta: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(idx <= 1)

                                Button {
                                    subStore.moveCustom(at: idx, delta: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(idx >= subStore.subAgents.count - 1)
                            }
                        }
                        .tag(def.id)
                    }
                }
                Divider()
                HStack {
                    Button {
                        addNewSubAgent()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!subStore.canAddSubAgent)
                    .help("添加自定义子代理（最多 \(SubAgentLimits.maxCount) 个）")

                    Button {
                        guard selection != SubAgentDefinition.builtInId else { return }
                        let toDelete = selection
                        selection = SubAgentDefinition.builtInId
                        subStore.removeSubAgent(id: toDelete)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == SubAgentDefinition.builtInId)
                    Spacer()
                    Text("\(subStore.subAgents.count)/\(SubAgentLimits.maxCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)

            Form {
                Section("全局轻量模型组（sub_model）") {
                    Picker("当子代理请求 sub_model 时使用", selection: $store.settings.subGroupID) {
                        Text("未配置（回退跟随父会话）").tag(UUID?.none)
                        ForEach(store.settings.groups) { g in
                            Text(g.name).tag(UUID?.some(g.id))
                        }
                    }
                }

                Section(draft.isBuiltIn ? "内置通用子代理（名称与描述固定）" : "自定义子代理编辑") {
                    TextField("名称（最多 \(SubAgentLimits.nameMaxLength) 字符）", text: $draft.name)
                        .disabled(draft.isBuiltIn)
                    TextField("职责描述（主模型据此选择子代理，最多 \(SubAgentLimits.descriptionMaxLength) 字符）", text: $draft.description)
                        .disabled(draft.isBuiltIn)
                    Picker("模型分组绑定", selection: $draft.modelGroupID) {
                        Text("Auto（由主模型按任务选择 same_as_me / default_model / sub_model）").tag(UUID?.none)
                        ForEach(store.settings.groups) { g in
                            Text("固定：\(g.name)").tag(UUID?.some(g.id))
                        }
                    }
                    Picker("思考档位覆盖", selection: $draft.thinkingLevelOverride) {
                        Text("跟随分组或父对话").tag(ThinkingLevel?.none)
                        ForEach(ThinkingLevel.allCases) { t in
                            Text(t.label).tag(ThinkingLevel?.some(t))
                        }
                    }
                }

                Section("附加子代理指令（仅注入该子代理会话，最多 \(SubAgentLimits.instructionsMaxLength) 字符）") {
                    TextEditor(text: $draft.instructions)
                        .font(.body.monospaced())
                        .frame(minHeight: 110)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("保存子代理配置") {
                        saveDraft()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { loadSelection() }
        .onChange(of: selection) { _, _ in loadSelection() }
    }

    private func loadSelection() {
        errorMessage = nil
        if let found = subStore.subAgent(id: selection) {
            draft = found
        } else if let first = subStore.subAgents.first {
            selection = first.id
            draft = first
        }
    }

    private func addNewSubAgent() {
        var n = 1
        var candidate = "Custom Agent \(n)"
        while subStore.subAgentNameIsTaken(candidate, excluding: nil) {
            n += 1
            candidate = "Custom Agent \(n)"
        }
        let created = SubAgentDefinition(
            name: candidate,
            description: "Specialized sub-agent for targeted tasks."
        )
        subStore.upsertSubAgent(created)
        selection = created.id
        draft = created
    }

    private func saveDraft() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isBuiltIn {
            guard !trimmedName.isEmpty else {
                errorMessage = "子代理名称不能为空"
                return
            }
            guard !subStore.subAgentNameIsTaken(trimmedName, excluding: draft.id) else {
                errorMessage = "已存在同名子代理「\(trimmedName)」"
                return
            }
        }
        errorMessage = nil
        subStore.upsertSubAgent(draft)
        loadSelection()
    }
}

// MARK: - Scheduled Tasks & Background Settings Tab

struct ScheduledAndBackgroundSettings: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var registry = AgentJobRegistry.shared
    @ObservedObject var keepAlive = BackgroundKeepAliveManager.shared

    @State private var newLabel = ""
    @State private var newPrompt = ""
    @State private var newMode = "after"      // after | interval | time
    @State private var newTiming = "10m"
    @State private var newCount = ""
    @State private var newTarget = "follow-up"
    @State private var newCommand = ""
    @State private var createError: String? = nil
    @State private var inspectSessionID: UUID? = nil

    var body: some View {
        Form {
            Section("macOS 后台保活与状态栏（对应上游 Background）") {
                Toggle("有对话、子代理或定时任务运行时阻止系统空闲睡眠（ProcessInfo Activity）",
                       isOn: $keepAlive.preventSleepWhileActive)
                Toggle("在 macOS 顶部菜单栏显示 OpenMinis 任务状态图标",
                       isOn: $keepAlive.showMenuBarExtra)
                Toggle("应用在后台完成子代理或触发定时任务时发送系统通知",
                       isOn: $keepAlive.notifyOnBackgroundCompletion)
                HStack {
                    Circle()
                        .fill(keepAlive.isHoldingSleepAssertion ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text("当前状态：\(keepAlive.statusSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("新建定时任务") {
                HStack {
                    TextField("任务名称", text: $newLabel)
                    Picker("触发类型", selection: $newMode) {
                        Text("单次延时（after）").tag("after")
                        Text("循环间隔（interval）").tag("interval")
                        Text("每日定时（time HH:MM）").tag("time")
                    }
                    .frame(width: 200)
                }
                HStack {
                    TextField(newMode == "time" ? "时间（如 09:00）" : "时长（如 30s / 10m / 1h）", text: $newTiming)
                    if newMode == "interval" {
                        TextField("次数（留空不限）", text: $newCount)
                            .frame(width: 120)
                    }
                    Picker("投递目标", selection: $newTarget) {
                        Text("当前选中对话（follow-up）").tag("follow-up")
                        Text("新建独立对话（new）").tag("new")
                        Text("隐藏子代理（child-of-current）").tag("child-of-current")
                    }
                }
                TextField("触发提示词（必填）", text: $newPrompt)
                TextField("预设先执行的 Shell 命令（可选，如 date 或 git status）", text: $newCommand)
                    .font(.body.monospaced())
                if let createError {
                    Text(createError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("创建定时任务") { createFromUI() }
                        .disabled(newPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("定时任务列表") {
                let timers = registry.jobs.filter { $0.isScheduledTimer }.reversed()
                if timers.isEmpty {
                    Text("暂无定时任务").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(timers)) { job in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(job.title) · \(job.trigger.logLabel)")
                                    .font(.callout.bold())
                                Text("状态：\(job.state.rawValue) · 已触发 \(job.firedCount) 次"
                                     + (job.nextFireAt.map { " · 下次：\(SessionExport.stamp.string(from: $0))" } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if job.state == .pending {
                                Button("立即运行") { registry.runNowScheduledJob(job) }
                                    .controlSize(.small)
                                Button("跳过下次") { registry.skipNextScheduledRun(job) }
                                    .controlSize(.small)
                                Button(job.isEnabled ? "暂停" : "恢复") {
                                    registry.setScheduledJobEnabled(id: job.id, enabled: !job.isEnabled)
                                }
                                .controlSize(.small)
                            }
                            Button("删除", role: .destructive) {
                                registry.deleteJob(id: job.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("最近子代理运行记录") {
                let subs = registry.jobs.filter { $0.isSubAgentJob }.suffix(15).reversed()
                if subs.isEmpty {
                    Text("暂无子代理运行记录").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(subs)) { job in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(job.title)（\(job.subAgentName ?? "General")）")
                                    .font(.callout.bold())
                                Text("\(job.state.rawValue) · \(job.summaryString)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let cid = job.runConversationID, store.conversation(cid) != nil {
                                Button("查看记录") { inspectSessionID = cid }
                                    .controlSize(.small)
                            }
                            if job.state == .running || job.state == .queued {
                                Button("停止", role: .destructive) {
                                    registry.cancel(jobId: job.id, reason: "stopped in settings")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(
            get: { inspectSessionID.map(UUIDIdentifiable.init) },
            set: { inspectSessionID = $0?.id }
        )) { item in
            SubAgentTranscriptSheet(conversationID: item.id)
                .environmentObject(store)
        }
    }

    private func createFromUI() {
        createError = nil
        var args: [String: Any] = [
            "action": "create",
            "prompt": newPrompt,
            "target": newTarget,
        ]
        if !newLabel.trimmingCharacters(in: .whitespaces).isEmpty { args["label"] = newLabel }
        if !newCommand.trimmingCharacters(in: .whitespaces).isEmpty { args["command"] = newCommand }
        args[newMode] = newTiming
        if newMode == "interval", let c = Int(newCount.trimmingCharacters(in: .whitespaces)), c > 0 {
            args["count"] = c
        }
        Task {
            let res = await registry.runScheduledTaskTool(args: args, callerConversationID: store.selectedID)
            if res.isError {
                createError = res.output
            } else {
                newPrompt = ""
                newLabel = ""
                newCommand = ""
            }
        }
    }
}

// MARK: - macOS MenuBarExtra View

struct MenuBarJobsView: View {
    @ObservedObject var keepAlive = BackgroundKeepAliveManager.shared
    @ObservedObject var registry = AgentJobRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OpenMinis 状态：\(keepAlive.statusSummary)")
                .font(.caption.bold())
            Divider()
            let activeSubs = registry.jobs.filter { $0.isSubAgentJob && ($0.state == .running || $0.state == .queued) }
            if !activeSubs.isEmpty {
                Text("运行中子代理").font(.caption2).foregroundStyle(.secondary)
                ForEach(activeSubs) { j in
                    Button("🤖 \(j.title)（点击停止）") {
                        registry.cancel(jobId: j.id, reason: "stopped from menu bar")
                    }
                }
                Divider()
            }
            let timers = registry.jobs.filter { $0.isScheduledTimer && $0.state == .pending && $0.isEnabled }
            if !timers.isEmpty {
                Text("待命定时任务").font(.caption2).foregroundStyle(.secondary)
                ForEach(timers) { j in
                    Button("⏰ 立即运行：\(j.title)") {
                        registry.runNowScheduledJob(j)
                    }
                }
                Divider()
            }
            Button("激活主窗口") {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(8)
    }
}
