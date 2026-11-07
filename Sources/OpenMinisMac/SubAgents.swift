import Foundation

// Port of upstream Providers/SubAgentDefinition.swift, Agent/Jobs/AgentCallback.swift,
// Agent/Jobs/ModelTierResolver.swift, ScheduledTargetDelivery.swift & ScheduledPresetToolCall.swift.
// Pure Foundation logic (no UI / WebKit), unit-tested off the main actor.

// MARK: - Sub Agent Limits & Definition (SubAgentDefinition.swift)

enum SubAgentLimits {
    /// Including the built-in general sub agent.
    static let maxCount = 10
    static let nameMaxLength = 40
    static let descriptionMaxLength = 200
    static let instructionsMaxLength = 4000
    /// Maximum concurrent child sub-agent runs per parent conversation.
    static let maxChildJobsPerParent = 3
    static let defaultMaxMinutes = 10
    static let maxMinutesCap = 60
    static let helperMaxTurns = 35
}

struct SubAgentDefinition: Identifiable, Codable, Hashable, Sendable {
    static let builtInId = "builtin.general"
    static let toolName = "subagent_task"
    static let builtInName = "General Sub Agent"
    static let builtInDescription =
        "Open-ended work that needs its own tool loop: exploring a codebase or the web over many rounds, "
        + "digesting bulk output into a conclusion, or running independent branches in parallel."

    var id: String = UUID().uuidString
    var name: String
    var description: String
    var instructions: String = ""
    var modelGroupID: UUID? = nil
    var thinkingLevelOverride: ThinkingLevel? = nil
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
    var updatedAt: Date = Date()

    var displayName: String { isBuiltIn ? "通用子代理（General Sub Agent）" : name }
    var displayDescription: String {
        isBuiltIn
            ? "需要独立工具循环的开放式任务：多轮探索代码库或网页、汇总提炼大量输出，或并行处理相互独立的子问题。"
            : description
    }

    init(id: String = UUID().uuidString,
         name: String,
         description: String,
         instructions: String = "",
         modelGroupID: UUID? = nil,
         thinkingLevelOverride: ThinkingLevel? = nil,
         isBuiltIn: Bool = false,
         sortOrder: Int = 0,
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.modelGroupID = modelGroupID
        self.thinkingLevelOverride = thinkingLevelOverride
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, instructions, modelGroupID, thinkingLevelOverride, isBuiltIn, sortOrder, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.builtInName
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        modelGroupID = try? c.decodeIfPresent(UUID.self, forKey: .modelGroupID)
        thinkingLevelOverride = try? c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevelOverride)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? (id == Self.builtInId)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    static func makeBuiltIn(sortOrder: Int = 0) -> SubAgentDefinition {
        SubAgentDefinition(
            id: builtInId,
            name: builtInName,
            description: builtInDescription,
            instructions: "",
            modelGroupID: nil,
            thinkingLevelOverride: nil,
            isBuiltIn: true,
            sortOrder: sortOrder
        )
    }

    func clamped() -> SubAgentDefinition {
        var copy = self
        copy.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SubAgentLimits.nameMaxLength))
        copy.description = String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SubAgentLimits.descriptionMaxLength))
        copy.instructions = String(instructions.prefix(SubAgentLimits.instructionsMaxLength))
        return copy
    }
}

enum SubAgentRoster {
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Guarantees built-in first with canonical name/description, clamps fields,
    /// removes blank/duplicate names, caps at `maxCount`, and renumbers `sortOrder` 0..<N.
    static func normalize(_ input: [SubAgentDefinition]) -> [SubAgentDefinition] {
        var list = input
        var builtIn: SubAgentDefinition
        if let idx = list.firstIndex(where: { $0.id == SubAgentDefinition.builtInId || $0.isBuiltIn }) {
            builtIn = list.remove(at: idx).clamped()
            builtIn = SubAgentDefinition(
                id: SubAgentDefinition.builtInId,
                name: SubAgentDefinition.builtInName,
                description: SubAgentDefinition.builtInDescription,
                instructions: builtIn.instructions,
                modelGroupID: builtIn.modelGroupID,
                thinkingLevelOverride: builtIn.thinkingLevelOverride,
                isBuiltIn: true,
                sortOrder: 0,
                updatedAt: builtIn.updatedAt
            )
        } else {
            builtIn = SubAgentDefinition.makeBuiltIn(sortOrder: 0)
        }

        let orderedCustom = list
            .filter { $0.id != SubAgentDefinition.builtInId && !$0.isBuiltIn }
            .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }

        var result: [SubAgentDefinition] = [builtIn]
        var seenNames: Set<String> = [nameKey(builtIn.name)]

        for raw in orderedCustom {
            guard result.count < SubAgentLimits.maxCount else { break }
            var d = raw.clamped()
            let key = nameKey(d.name)
            guard !key.isEmpty, !seenNames.contains(key) else { continue }
            seenNames.insert(key)
            d.sortOrder = result.count
            result.append(d)
        }
        return result
    }

    /// Resolves a sub-agent by name (case-insensitive); nil/empty/unknown falls back to built-in.
    static func resolve(name: String?, in roster: [SubAgentDefinition]) -> SubAgentDefinition {
        let normalized = normalize(roster)
        let builtIn = normalized[0]
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return builtIn
        }
        let key = nameKey(raw)
        return normalized.first { nameKey($0.name) == key || $0.id.lowercased() == key } ?? builtIn
    }

    /// Builds the system-prompt section advertising the sub-agent roster.
    static func rosterSection(_ roster: [SubAgentDefinition], groupName: (UUID) -> String?) -> String {
        let list = normalize(roster)
        var lines = ["Available sub agents (pass the name as \(SubAgentDefinition.toolName).agent):"]
        for def in list {
            let desc = String(def.description.prefix(SubAgentLimits.descriptionMaxLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model: String
            if let gid = def.modelGroupID, let gname = groupName(gid) {
                model = "fixed — \(gname)"
            } else {
                model = "Auto — you choose with model_choice"
            }
            lines.append("- \(def.name) — \(desc) Model: \(model).")
        }
        lines.append("Prefer a specific sub agent when its description matches; otherwise use the general one.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Model Choice & Progress Cadence (ModelTierResolver.swift)

enum HelperModelOrigin: String, Codable, Sendable {
    case pinned
    case inherited
    case defaultGroup = "default_group"
    case subGroup = "sub_group"
}

enum SubAgentModelChoice: String, CaseIterable, Codable, Sendable {
    case sameAsParent = "same_as_me"
    case defaultModel = "default_model"
    case subModel = "sub_model"

    static func parse(_ raw: String?) -> SubAgentModelChoice {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let v = SubAgentModelChoice(rawValue: raw) else { return .sameAsParent }
        return v
    }
}

enum ProgressReportCadence: String, CaseIterable, Codable, Sendable {
    case none
    case frequent
    case moderate

    var intervalSeconds: TimeInterval? {
        switch self {
        case .none: return nil
        case .frequent: return 15
        case .moderate: return 60
        }
    }

    static func parse(_ raw: String?) -> ProgressReportCadence {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let v = ProgressReportCadence(rawValue: raw) else { return .none }
        return v
    }
}

// MARK: - Agent Callback XML Envelope (AgentCallback.swift)

struct AgentCallback: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case progress
        case finished
        case scheduled
    }

    static let tag = "agent_callback"

    var kind: Kind
    var jobId: String
    var childSessionId: String?
    var title: String
    /// running · done · cancelled · timeout · failed · interrupted
    var status: String
    var modelOrigin: String?
    var modelResolved: String?
    var agent: String?
    var elapsed: String?
    var tool: String?
    var activity: String?
    var turn: Int?
    var summary: String?
    var body: String
    var siblings: String?
    var fireIndex: Int?
    var remaining: Int?
    var triggerLabel: String?
    var nextFireAt: String?

    static func isCallbackText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<\(tag) ") || t.hasPrefix("<\(tag)>")
    }

    static func bodyTag(for kind: Kind) -> String {
        switch kind {
        case .finished: return "result"
        case .progress: return "last_message"
        case .scheduled: return "prompt"
        }
    }

    var xml: String {
        var attrs: [(String, String)] = [("kind", kind.rawValue), ("job", jobId)]
        if let childSessionId, !childSessionId.isEmpty { attrs.append(("session", childSessionId)) }
        attrs.append(("title", title))
        attrs.append(("status", status))
        if let modelOrigin, !modelOrigin.isEmpty { attrs.append(("model", modelOrigin)) }
        if let modelResolved, !modelResolved.isEmpty { attrs.append(("model_resolved", modelResolved)) }
        if let agent, !agent.isEmpty, agent != SubAgentDefinition.builtInName { attrs.append(("agent", agent)) }
        if let elapsed, !elapsed.isEmpty { attrs.append(("elapsed", elapsed)) }
        if let tool, !tool.isEmpty { attrs.append(("tool", tool)) }
        if let activity, !activity.isEmpty { attrs.append(("activity", activity)) }
        if let turn, turn > 0 { attrs.append(("turn", String(turn))) }
        if let fireIndex, fireIndex > 0 { attrs.append(("fire", String(fireIndex))) }
        if let remaining, remaining >= 0 { attrs.append(("remaining", String(remaining))) }
        if let triggerLabel, !triggerLabel.isEmpty { attrs.append(("trigger", triggerLabel)) }
        if let nextFireAt, !nextFireAt.isEmpty { attrs.append(("next_fire_at", nextFireAt)) }

        let open = "<\(Self.tag) " + attrs.map { "\($0.0)=\"\(Self.escapeAttr($0.1))\"" }.joined(separator: " ") + ">"
        var lines: [String] = [open]
        if let summary, !summary.isEmpty { lines.append("<summary>\(Self.escapeText(summary))</summary>") }
        if let siblings, !siblings.isEmpty { lines.append("<other_sub_agents>\(Self.escapeText(siblings))</other_sub_agents>") }
        let bTag = Self.bodyTag(for: kind)
        lines.append("<\(bTag)>")
        lines.append(body)
        lines.append("</\(bTag)>")
        lines.append("</\(Self.tag)>")
        return lines.joined(separator: "\n")
    }

    static func parse(_ raw: String) -> AgentCallback? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCallbackText(text), let openEnd = text.firstIndex(of: ">") else { return nil }
        let open = String(text[text.index(text.startIndex, offsetBy: tag.count + 1)..<openEnd])
        let attrs = parseAttributes(open)
        guard let kindRaw = attrs["kind"], let kind = Kind(rawValue: kindRaw),
              let jobId = attrs["job"] else { return nil }
        let bTag = bodyTag(for: kind)
        let bodyContent = extractElement(bTag, in: text, rawBody: true) ?? ""
        return AgentCallback(
            kind: kind,
            jobId: jobId,
            childSessionId: attrs["session"],
            title: attrs["title"] ?? "",
            status: attrs["status"] ?? "done",
            modelOrigin: attrs["model"],
            modelResolved: attrs["model_resolved"],
            agent: attrs["agent"],
            elapsed: attrs["elapsed"],
            tool: attrs["tool"],
            activity: attrs["activity"],
            turn: attrs["turn"].flatMap(Int.init),
            summary: extractElement("summary", in: text, rawBody: false),
            body: bodyContent,
            siblings: extractElement("other_sub_agents", in: text, rawBody: false),
            fireIndex: attrs["fire"].flatMap(Int.init),
            remaining: attrs["remaining"].flatMap(Int.init),
            triggerLabel: attrs["trigger"],
            nextFireAt: attrs["next_fire_at"]
        )
    }

    static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func parseAttributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"([A-Za-z0-9_]+)="([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let kr = Range(m.range(at: 1), in: s), let vr = Range(m.range(at: 2), in: s) {
                out[String(s[kr])] = unescape(String(s[vr]))
            }
        }
        return out
    }

    private static func extractElement(_ name: String, in text: String, rawBody: Bool) -> String? {
        let openTag = "<\(name)>"
        let closeTag = "</\(name)>"
        guard let start = text.range(of: openTag),
              let end = text.range(of: closeTag, options: rawBody ? .backwards : [], range: start.upperBound..<text.endIndex) else {
            return nil
        }
        var inner = String(text[start.upperBound..<end.lowerBound])
        if rawBody {
            if inner.hasPrefix("\n") { inner.removeFirst() }
            if inner.hasSuffix("\n") { inner.removeLast() }
            return inner
        }
        return unescape(inner)
    }
}

// MARK: - Scheduled Target Delivery & Preset Tool Call

enum ScheduledTargetDelivery {
    static func resolveTarget(explicit: String?, session: String?, callerSession: String?) -> (target: String, defaulted: Bool) {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return (explicit.lowercased(), false)
        }
        return ((session ?? callerSession) != nil ? "follow-up" : "new", true)
    }

    enum Destination: Equatable, Sendable {
        case followUp(sessionId: String, title: String?, isCallerSession: Bool)
        case newChat(label: String?)
        case rerun(sessionId: String, messageId: String, title: String?)
        case childOfCurrent(parentSessionId: String, isCallerSession: Bool)

        var kind: String {
            switch self {
            case .followUp: return "follow-up"
            case .newChat: return "new"
            case .rerun: return "rerun"
            case .childOfCurrent: return "child-of-current"
            }
        }
    }

    static func sentence(_ d: Destination, defaulted: Bool) -> String {
        switch d {
        case .followUp(let sid, let title, let isCaller):
            let name = sessionName(sid, title)
            if isCaller {
                return "Delivery: each fire runs as a new turn IN THIS CHAT (\(name))."
                    + (defaulted ? " --target defaulted to follow-up because this command ran inside a chat; to use a separate chat instead, delete this task and re-create it with --target new." : "")
            }
            return "Delivery: each fire runs as a new turn in ANOTHER chat (\(name)), NOT in this conversation."
        case .newChat(let label):
            let titled = label.map { " titled “Scheduled · \($0)”" } ?? ""
            return "Delivery: each fire opens a NEW, separate chat\(titled); the result will NOT appear in this conversation."
                + (defaulted ? " --target defaulted to new because no chat was running this command." : "")
        case .rerun(let sid, let mid, let title):
            return "Delivery: each fire RE-RUNS user message \(mid.prefix(8)) in \(sessionName(sid, title))."
        case .childOfCurrent(let parent, let isCaller):
            let whose = isCaller ? "this chat" : "chat \(parent.prefix(8))"
            return "Delivery: each fire starts a hidden helper agent under \(whose); its final answer is posted back into \(whose)."
        }
    }

    private static func sessionName(_ sid: String, _ title: String?) -> String {
        if let title, !title.isEmpty { return "session \(sid.prefix(8)) “\(title)”" }
        return "session \(sid.prefix(8))"
    }
}

struct ScheduledPresetToolCall: Codable, Equatable, Sendable {
    var command: String
    var timeoutSeconds: Int? = nil

    static let maxCommandLength = 16_000
    static let timeoutRange: ClosedRange<Int> = 1...3600

    var envelopeNote: String {
        "[This task's first step already ran for you: shell — its call and output follow. Work from that output; re-run only if it failed.]\n"
    }

    static func makeToolUseId() -> String {
        "toolu_sched_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    }

    enum PresetError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let m): return m }
        }
    }

    static func parse(command: String?, timeoutSeconds: Double?, toolArgsJSON: String? = nil) -> Result<ScheduledPresetToolCall?, PresetError> {
        var cmd = command
        var timeout: Int? = nil
        if let t = timeoutSeconds {
            guard t.isFinite, t >= 1, t <= 3600 else {
                return .failure(.invalid("--command-timeout must be between 1s and 1h"))
            }
            timeout = Int(t.rounded())
        }
        if let toolArgsJSON, !toolArgsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard cmd == nil else {
                return .failure(.invalid("use either command or tool_args, not both"))
            }
            guard let data = toolArgsJSON.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let c = obj["command"] as? String else {
                return .failure(.invalid("tool_args must be a JSON object with a \"command\" string"))
            }
            cmd = c
            if timeout == nil, let tn = obj["timeout"] as? NSNumber {
                let v = tn.intValue
                guard timeoutRange.contains(v) else { return .failure(.invalid("timeout must be between 1s and 3600s")) }
                timeout = v
            }
        }
        guard let finalCmd = cmd?.trimmingCharacters(in: .whitespacesAndNewlines), !finalCmd.isEmpty else {
            return .success(nil)
        }
        guard finalCmd.count <= maxCommandLength else {
            return .failure(.invalid("command is longer than \(maxCommandLength) characters"))
        }
        return .success(ScheduledPresetToolCall(command: finalCmd, timeoutSeconds: timeout))
    }
}

// MARK: - Schedule Duration & Cron Parser

enum ScheduleParser {
    /// Parses duration strings like `"30s"`, `"10m"`, `"2h"`, `"1d"`, `"1h30m"`, or plain seconds `"60"`.
    static func parseDuration(_ raw: String?) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        if let plain = Double(raw), plain.isFinite, plain > 0 { return plain }
        let pattern = #"(\d+(?:\.\d+)?)\s*(s|sec|secs|m|min|mins|h|hr|hrs|d|day|days)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard !matches.isEmpty else { return nil }
        var total: TimeInterval = 0
        var matchedChars = 0
        for m in matches {
            guard let nr = Range(m.range(at: 1), in: raw),
                  let ur = Range(m.range(at: 2), in: raw),
                  let val = Double(raw[nr]), val.isFinite else { return nil }
            let unit = String(raw[ur])
            let mult: Double
            switch unit.first {
            case "s": mult = 1
            case "m": mult = 60
            case "h": mult = 3600
            case "d": mult = 86400
            default: return nil
            }
            total += val * mult
            matchedChars += m.range.length
        }
        let stripped = raw.replacingOccurrences(of: " ", with: "")
        guard matchedChars == stripped.count, total > 0 else { return nil }
        return total
    }

    /// Parses `"HH:MM"` (24-hour) into `(hour: 0...23, minute: 0...59)`.
    static func parseTimeOfDay(_ raw: String?) -> (hour: Int, minute: Int)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// Converts `--repeat daily|weekdays|weekends|custom` and `--days mon,fri` into Calendar weekday ints (`1=Sun ... 7=Sat`).
    static func parseWeekdays(repeatMode: String?, daysRaw: String?) -> Set<Int>? {
        let mode = repeatMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? (daysRaw != nil ? "custom" : "daily")
        switch mode {
        case "daily", "everyday", "all":
            return Set(1...7)
        case "weekdays", "weekday", "workdays":
            return [2, 3, 4, 5, 6]
        case "weekends", "weekend":
            return [1, 7]
        case "custom":
            guard let daysRaw else { return nil }
            return parseDaysList(daysRaw)
        default:
            if let d = parseDaysList(mode) { return d }
            return nil
        }
    }

    static func parseDaysList(_ raw: String) -> Set<Int>? {
        let map: [String: Int] = [
            "sun": 1, "sunday": 1, "7": 1, "日": 1, "周日": 1,
            "mon": 2, "monday": 2, "1": 2, "一": 2, "周一": 2,
            "tue": 3, "tues": 3, "tuesday": 3, "2": 3, "二": 3, "周二": 3,
            "wed": 4, "wednesday": 4, "3": 4, "三": 4, "周三": 4,
            "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "4": 5, "四": 5, "周四": 5,
            "fri": 6, "friday": 6, "5": 6, "五": 6, "周五": 6,
            "sat": 7, "saturday": 7, "6": 7, "六": 7, "周六": 7,
        ]
        var out: Set<Int> = []
        for token in raw.lowercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            guard let w = map[String(token)] else { return nil }
            out.insert(w)
        }
        return out.isEmpty ? nil : out
    }

    /// Computes the next calendar fire date strictly after `from`.
    static func nextCronDate(hour: Int, minute: Int, days: Set<Int>,
                             start: Date? = nil, end: Date? = nil,
                             from: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        let validDays = days.isEmpty ? Set(1...7) : days
        let base = max(from, start ?? .distantPast)
        for dayOffset in 0...14 {
            guard let dayDate = cal.date(byAdding: .day, value: dayOffset, to: base) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: dayDate)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let candidate = cal.date(from: comps) else { continue }
            if candidate <= base { continue }
            let weekday = cal.component(.weekday, from: candidate)
            guard validDays.contains(weekday) else { continue }
            if let end, candidate > end { return nil }
            return candidate
        }
        return nil
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let rem = s % 60
        if m < 60 { return rem == 0 ? "\(m)m" : "\(m)m\(String(format: "%02d", rem))s" }
        let h = m / 60
        let rm = m % 60
        return "\(h)h\(String(format: "%02d", rm))m"
    }
}
