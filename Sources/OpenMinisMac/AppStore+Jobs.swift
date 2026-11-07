import Foundation

// Programmatic turn delivery, queued follow-ups, and child sub-agent loop execution.

extension AppStore {
    /// Injects a callback or scheduled task envelope into `id`, queueing it if `id` is busy.
    func deliverProgrammaticTurn(_ text: String, to id: UUID,
                                 preset: ScheduledPresetToolCall? = nil,
                                 presetTitle: String? = nil) {
        guard conversation(id) != nil else { return }
        if isRunning(id) {
            queuedTurns[id, default: []].append(QueuedTurn(text: text, preset: preset, presetTitle: presetTitle))
            return
        }
        if let preset {
            pendingPresets[id] = (call: preset, title: presetTitle ?? "Scheduled Command")
        }
        append(ChatMessage(role: .user, content: text), to: id)
        touch(id)
        saveConversations()
        start(id)
    }

    func drainQueuedTurnsIfNeeded(_ id: UUID) {
        guard !isRunning(id), var q = queuedTurns[id], !q.isEmpty else { return }
        let next = q.removeFirst()
        queuedTurns[id] = q.isEmpty ? nil : q
        deliverProgrammaticTurn(next.text, to: id, preset: next.preset, presetTitle: next.presetTitle)
    }

    /// Runs a delegated sub-agent inside its isolated hidden child conversation.
    func runChildSubAgent(job: AgentJob, childConversationID id: UUID) async {
        guard conversation(id) != nil else {
            AgentJobRegistry.shared.finishSubAgentRun(job, state: .failed, result: "Child conversation not found.")
            return
        }
        let parentID = job.target.parentConversationID ?? id
        guard let g = group(for: id) else {
            AgentJobRegistry.shared.finishSubAgentRun(job, state: .failed, result: "No model group configured.")
            return
        }
        let cands = ModelRouter.candidates(group: g, sessionKey: parentID.uuidString, isAvailable: { [unowned self] in self.isAvailable($0) })
        if cands.isEmpty {
            AgentJobRegistry.shared.finishSubAgentRun(job, state: .failed, result: "Model group '\(g.name)' has no available models.")
            return
        }

        if job.wasResumed, !(conversation(id)?.messages.isEmpty ?? true) {
            append(ChatMessage(role: .user, content: "[System: Your previous run was interrupted. Continue from the progress above and produce the final answer.]"), to: id)
        } else if let brief = job.prompt {
            append(ChatMessage(role: .user, content: brief), to: id)
        }
        saveConversations()

        runningIDs.insert(id)
        AgentJobRegistry.shared.syncKeepAliveCounts()
        defer {
            runningIDs.remove(id)
            saveConversations()
            AgentJobRegistry.shared.syncKeepAliveCounts()
        }

        let requested = thinking(for: id)
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let runner = ToolRunner(workspace: workspaceURL, memoryEnabled: false,
                                conversationID: id, allowSubAgents: false,
                                onSkillFile: { [weak self] sid, wrote in
                                    Task { @MainActor in self?.skillTouched(sid, wrote: wrote) }
                                }) { [weak self] cmd in
            guard let self else { return false }
            return await self.requestApproval(cmd, conversation: parentID)
        }
        let specs = ToolRunner.specs(memory: false, allowSubAgents: false)
        var ci = 0

        for _ in 0..<SubAgentLimits.helperMaxTurns {
            if Task.isCancelled || job.state != .running { return }

            // Drain any steering messages queued via `subagent_task(action: "steer")`
            if !job.pendingSteers.isEmpty {
                let steers = job.pendingSteers
                job.pendingSteers.removeAll()
                job.appliedSteers.append(contentsOf: steers)
                let combined = steers.enumerated().map { "Steer \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
                append(ChatMessage(role: .user, content: "[Course correction from parent agent]\n\(combined)"), to: id)
                saveConversations()
            }

            job.turnsCount += 1
            job.currentTool = ""
            let assistant = ChatMessage(role: .assistant, content: "")
            append(assistant, to: id)
            var calls: [ToolCall] = []
            var retryAttempt = 0

            attempt: while true {
                guard ci < cands.count, let e = entry(cands[ci]), let inst = instance(e.instanceID) else {
                    AgentJobRegistry.shared.finishSubAgentRun(job, state: .failed, result: "All models in group '\(g.name)' failed.")
                    return
                }
                let label = entryLabel(e)
                job.modelResolvedLabel = label
                mutate(id, assistant.id) {
                    $0.content = ""; $0.reasoning = ""; $0.reasoningSignature = nil
                    $0.toolCalls = []; $0.usage = nil; $0.modelLabel = label
                }
                calls = []
                var lastUsage: TokenUsage? = nil
                let ctx = RequestContext(instance: inst, entry: e, apiKey: inst.apiKey,
                                         thinking: e.effectiveThinking(requested))
                do {
                    let stream = makeClient(ctx).stream(system: systemPrompt(id),
                                                        messages: apiHistory(id, limit: g.contextLimitTokens),
                                                        tools: specs)
                    for try await ev in stream {
                        switch ev {
                        case .text(let t):
                            mutate(id, assistant.id) { $0.content += t }
                        case .reasoning(let r):
                            mutate(id, assistant.id) { $0.reasoning += r }
                        case .reasoningSignature(let s):
                            mutate(id, assistant.id) { $0.reasoningSignature = s }
                        case .toolCall(let tc):
                            calls.append(tc)
                            mutate(id, assistant.id) { $0.toolCalls.append(tc) }
                        case .usage(let u):
                            lastUsage = u
                            mutate(id, assistant.id) { $0.usage = u }
                        }
                    }
                    if let u = lastUsage { recordUsage(u, entry: e) }
                    break attempt
                } catch {
                    if Task.isCancelled || error is CancellationError || job.state != .running { return }
                    if (error as? URLError)?.code == .cancelled { return }
                    let le = LLMError.wrap(error)
                    let hasNext = ci + 1 < cands.count
                    if g.fallbackPolicy == .limited && le.isTransient {
                        let delays = ModelRouter.retryDelays(for: le, hasFallbackTarget: hasNext)
                        if retryAttempt < delays.count {
                            let wait = delays[retryAttempt]
                            retryAttempt += 1
                            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                            if Task.isCancelled || job.state != .running { return }
                            continue attempt
                        }
                    }
                    if hasNext {
                        ci += 1
                        retryAttempt = 0
                        continue attempt
                    }
                    mutate(id, assistant.id) { $0.toolCalls = [] }
                    let partial = AgentJobRegistry.shared.latestChildAnswer(in: id)
                    let errResult = (partial.isEmpty ? "" : partial + "\n\n") + "[Error (\(label)): \(le.message)]"
                    AgentJobRegistry.shared.finishSubAgentRun(job, state: .failed, result: errResult)
                    return
                }
            }

            if calls.isEmpty {
                let finalAnswer = AgentJobRegistry.shared.latestChildAnswer(in: id)
                AgentJobRegistry.shared.finishSubAgentRun(
                    job,
                    state: .done,
                    result: finalAnswer.isEmpty ? "(Sub-agent completed with no text output.)" : finalAnswer
                )
                return
            }

            for tc in calls {
                if Task.isCancelled || job.state != .running { return }
                job.currentTool = tc.name
                job.toolCallsSummary[tc.name, default: 0] += 1
                let r = await runner.run(tc)
                if Task.isCancelled || job.state != .running { return }
                append(ChatMessage(role: .tool, content: r.output, toolCallId: tc.id, toolName: tc.name, isError: r.isError), to: id)
            }
            job.currentTool = ""
            saveConversations()
        }

        let partial = AgentJobRegistry.shared.latestChildAnswer(in: id)
        AgentJobRegistry.shared.finishSubAgentRun(
            job,
            state: .done,
            result: (partial.isEmpty ? "" : partial + "\n\n") + "[Reached maximum sub-agent turns (\(SubAgentLimits.helperMaxTurns)).]"
        )
    }
}
