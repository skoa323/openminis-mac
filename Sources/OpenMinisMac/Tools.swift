import Foundation

struct ToolResult {
    var output: String
    var isError: Bool = false
}

/// Thread-safe byte accumulator used while draining process pipes.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

final class ToolRunner {
    let workspace: URL
    let memoryEnabled: Bool
    let conversationID: UUID?
    let allowSubAgents: Bool
    /// Called before running a shell command. Return false to reject.
    let approve: (String) async -> Bool
    /// Called after a skill's SKILL.md is read (`write == false`) or written/edited (`write == true`).
    let onSkillFile: (String, Bool) -> Void

    init(workspace: URL, memoryEnabled: Bool = true,
         conversationID: UUID? = nil,
         allowSubAgents: Bool = true,
         onSkillFile: @escaping (String, Bool) -> Void = { _, _ in },
         approve: @escaping (String) async -> Bool) {
        self.workspace = workspace
        self.memoryEnabled = memoryEnabled
        self.conversationID = conversationID
        self.allowSubAgents = allowSubAgents
        self.onSkillFile = onSkillFile
        self.approve = approve
    }

    static let maxOutput = 30_000

    // MARK: - Specs

    static var specs: [ToolSpec] { specs(memory: true) }

    static func specs(memory: Bool, allowSubAgents: Bool = true, subAgentNames: [String] = [SubAgentDefinition.builtInName]) -> [ToolSpec] {
        func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
        func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
        func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }

        let base: [ToolSpec] = [
            ToolSpec(name: "shell",
                     description: "在本机 macOS 上用 /bin/zsh 执行命令，工作目录为工作区。返回 stdout、stderr 和退出码。",
                     parameters: obj(["command": str("要执行的 shell 命令"),
                                      "timeout": int("超时秒数，默认 120")], ["command"])),
            ToolSpec(name: "read_file",
                     description: "读取文本文件。相对路径基于工作区。可用 offset（从 1 开始的行号）和 limit 分段读取。",
                     parameters: obj(["path": str("文件路径"),
                                      "offset": int("起始行号，从 1 开始"),
                                      "limit": int("最多读取的行数")], ["path"])),
            ToolSpec(name: "write_file",
                     description: "创建或覆盖文本文件，自动创建父目录。",
                     parameters: obj(["path": str("文件路径"), "content": str("文件内容")], ["path", "content"])),
            ToolSpec(name: "edit_file",
                     description: "精确字符串替换。old_string 必须在文件中唯一出现，除非 replace_all 为 true。",
                     parameters: obj(["path": str("文件路径"),
                                      "old_string": str("要替换的原文"),
                                      "new_string": str("替换后的文本"),
                                      "replace_all": bool("替换所有出现")], ["path", "old_string", "new_string"])),
            ToolSpec(name: "list_dir",
                     description: "列出目录内容，目录以 / 结尾。",
                     parameters: obj(["path": str("目录路径，默认工作区")], [])),
            ToolSpec(name: "web_fetch",
                     description: "HTTP GET 获取网页或 API 内容，HTML 会转为纯文本。",
                     parameters: obj(["url": str("http(s) 地址")], ["url"])),
            ToolSpec(name: "browser_use",
                     description: "控制内置多标签页 WKWebView 浏览器：支持 navigate、screenshot、click、type、get_text、get_readable、get_backbone、find_elements、scroll、scroll_and_collect、execute_js、hover、wait_for_dom_stable、get_page_info、new_tab、close_tab、list_tabs、get_cookies、set_cookies、set_user_agent、set_viewport、fetch。适合动态网页渲染、页面交互、登录会话与截图。",
                     parameters: obj([
                         "action": ["type": "string", "enum": BrowserAction.allCases.map(\.rawValue), "description": "要执行的浏览器动作"],
                         "url": str("navigate 目标网址（支持 http/https/file）或 fetch 资源地址"),
                         "selector": str("CSS 选择器（用于 click/type/get_text/scroll/hover/find_elements）"),
                         "text": str("要输入的文本（type 动作）"),
                         "script": str("要执行的 JavaScript 代码（execute_js，支持顶层 await 与 return）"),
                         "direction": ["type": "string", "enum": ["up", "down"], "description": "滚动方向（默认 down）"],
                         "amount": int("滚动像素距离（默认 500）"),
                         "coordinate_x": int("点击的 X 坐标（click 的替代方式）"),
                         "coordinate_y": int("点击的 Y 坐标（click 的替代方式）"),
                         "tab_id": int("目标标签页 ID（默认当前活动标签）"),
                         "user_agent": ["type": "string", "enum": ["desktop_safari", "mobile_safari"], "description": "切换当前标签的 User-Agent"],
                         "viewport_width": int("视口宽度 CSS 像素（set_viewport，200-4096）"),
                         "viewport_height": int("视口高度 CSS 像素（set_viewport，200-4096）"),
                         "reset": bool("set_viewport 时设为 true 以恢复默认视口"),
                         "full_page": bool("screenshot 时设为 true 以截取整页长图"),
                         "max_depth": int("get_backbone 最大树深度（默认 5）"),
                         "keywords": str("get_cookies 按名称筛选的空格分隔关键词"),
                         "fuzzy": bool("get_cookies 关键词是否模糊包含匹配（默认 true）"),
                         "cookies": str("set_cookies 的 Cookie JSON 数组字符串，每项含 name、value 等"),
                         "item_selector": str("scroll_and_collect 列表项 CSS 选择器"),
                         "scroll_count": int("scroll_and_collect 滚动步数（默认 10，最大 20）"),
                         "timeout": int("wait_for_dom_stable 超时秒数（默认 10）"),
                     ] as [String: Any], ["action"])),
        ]
        var out = base
        if allowSubAgents {
            let agentEnum = subAgentNames.isEmpty ? [SubAgentDefinition.builtInName] : subAgentNames
            out.append(ToolSpec(
                name: SubAgentDefinition.toolName,
                description: "将独立自包含的任务委派给子代理（Sub-Agent，在隐藏子会话中独立执行工具循环），或查询/调整/取消/恢复已启动的子代理。默认 action 为 delegate。每个父会话最多同时运行 \(SubAgentLimits.maxChildJobsPerParent) 个子代理，超出自动排队。wait=false（默认）立即返回 status=running 与 job_id，完成时以 <agent_callback> 新消息回调。",
                parameters: obj([
                    "tool_title": str("向用户展示的简短摘要（5-10 个词）"),
                    "action": ["type": "string", "enum": ["delegate", "status", "steer", "cancel", "resume"], "description": "delegate（默认）：启动子代理；status：查询状态；steer：向运行中的子代理追加修正指令；cancel：停止子代理；resume：恢复上次中断的子代理"],
                    "task": str("action=delegate 时必填：完整的任务说明（目标、路径/URL、约束、期望返回格式）"),
                    "agent": ["type": "string", "enum": agentEnum, "description": "action=delegate 时选择子代理名称，留空使用通用子代理"],
                    "model_choice": ["type": "string", "enum": ["same_as_me", "default_model", "sub_model"], "description": "当子代理未固定模型组时的模型选择（默认 same_as_me）"],
                    "context": str("action=delegate 时可选附带的原始上下文文本"),
                    "max_minutes": int("最大运行分钟数（默认 10，上限 60）"),
                    "wait": bool("false（默认）后台运行并异步回调；true 阻塞等待完成"),
                    "progress_report": ["type": "string", "enum": ["none", "frequent", "moderate"], "description": "后台运行时的进度汇报频率（none / frequent 15s / moderate 60s）"],
                    "job_id": str("action=status/steer/cancel/resume 时的目标 job_id（支持前缀匹配）"),
                    "message": str("action=steer 时必填：发给运行中子代理的修正指令"),
                    "child_session_id": str("action=resume 时可选指定子会话 ID"),
                ] as [String: Any], [])
            ))
            out.append(ToolSpec(
                name: "scheduled_task",
                description: "创建、查看、启停、立即执行或删除定时与延时任务（支持单次延时 after、循环间隔 interval+count、每日/周历时间 time+repeat+days、任务完成触发 of）。默认投递到当前对话（follow-up），也可新开对话（new）或后台子代理（child-of-current），并可预设每次触发自动先执行的 shell 命令（command）。",
                parameters: obj([
                    "action": ["type": "string", "enum": ["create", "list", "delete", "enable", "disable", "run", "skip_next"], "description": "要执行的定时任务操作"],
                    "prompt": str("create 时必填：每次触发时投递给模型的提示词"),
                    "label": str("任务简短名称"),
                    "after": str("单次延时触发（如 '30s'、'15m'、'2h'）"),
                    "interval": str("循环间隔触发（如 '10m'、'1h'）"),
                    "count": int("循环触发总次数（省略则持续循环）"),
                    "time": str("日历时间触发（24 小时制 HH:MM，如 '09:00'）"),
                    "repeat": ["type": "string", "enum": ["daily", "weekdays", "weekends", "custom"], "description": "日历重复模式（默认 daily）"],
                    "days": str("repeat=custom 时的星期列表（如 'mon,wed,fri'）"),
                    "of": str("链式触发：指定前序 job_id 完成后触发"),
                    "target": ["type": "string", "enum": ["follow-up", "new", "child-of-current"], "description": "投递目标（默认 follow-up 回到当前会话）"],
                    "command": str("可选：每次触发时自动先执行的 shell 命令"),
                    "command_timeout": int("预设 shell 命令超时秒数（1-3600）"),
                    "id": str("delete/enable/disable/run/skip_next 时的任务 ID（支持前缀）"),
                ] as [String: Any], ["action"])
            ))
        }
        guard memory else { return out }
        return out + [
            ToolSpec(name: "memory_write",
                     description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose. GLOBAL.md is read-only (user-maintained via Settings).",
                     parameters: obj(["content": str("The memory content to write. Use concise Markdown with a short heading (## Topic).")], ["content"])),
            ToolSpec(name: "memory_get",
                     description: "Retrieve memories from persistent storage. Keyword search over memory entries (any keyword matching counts); results ranked by 50% keyword coverage + 50% recency. Empty keywords returns full files.",
                     parameters: obj(["keywords": str("Space-separated keywords; empty = return full memory files"),
                                      "scope": ["type": "string", "enum": ["daily", "all"], "description": "daily = daily logs only, all = daily logs + GLOBAL.md (default)"]], [])),
        ]
    }

    // MARK: - Dispatch

    func run(_ call: ToolCall) async -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        do {
            switch call.name {
            case "shell": return try await shell(args)
            case "read_file": return try readFile(args)
            case "write_file": return try writeFile(args)
            case "edit_file": return try editFile(args)
            case "list_dir": return try listDir(args)
            case "web_fetch": return try await webFetch(args)
            case "browser_use": return await BrowserManager.shared.runTool(args)
            case "subagent_task":
                guard allowSubAgents, let cid = conversationID else {
                    return ToolResult(output: "Error: subagent_task is not available inside a sub-agent session.", isError: true)
                }
                return await AgentJobRegistry.shared.runSubAgentTool(args: args, parentConversationID: cid, toolUseID: call.id)
            case "scheduled_task":
                guard allowSubAgents else {
                    return ToolResult(output: "Error: scheduled_task is not available inside a sub-agent session.", isError: true)
                }
                return await AgentJobRegistry.shared.runScheduledTaskTool(args: args, callerConversationID: conversationID)
            case "memory_write", "memory_get":
                guard memoryEnabled else {
                    return ToolResult(output: "Memory is disabled for this session. Use /memory to re-enable.", isError: true)
                }
                return call.name == "memory_write" ? try memoryWrite(args) : memoryGet(args)
            default: return ToolResult(output: "未知工具：\(call.name)", isError: true)
            }
        } catch {
            return ToolResult(output: "错误：\(error.localizedDescription)", isError: true)
        }
    }

    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else { throw LLMError(message: "缺少参数 \(key)") }
        return v
    }

    private func intArg(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        if let s = args[key] as? String { return Int(s) }
        return nil
    }

    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return workspace.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func truncate(_ s: String, _ limit: Int = maxOutput) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n…（已截断，原长度 \(s.count) 字符）"
    }

    // MARK: - shell

    func runShellPreset(_ preset: ScheduledPresetToolCall) async -> ToolResult {
        var args: [String: Any] = ["command": preset.command]
        if let t = preset.timeoutSeconds { args["timeout"] = t }
        return (try? await shell(args)) ?? ToolResult(output: "Preset shell command failed to execute.", isError: true)
    }

    private func shell(_ args: [String: Any]) async throws -> ToolResult {
        let command = try string(args, "command")
        guard await approve(command) else {
            return ToolResult(output: "用户拒绝执行此命令。", isError: true)
        }
        let timeout = max(1, intArg(args, "timeout") ?? 120)
        let cwd = workspace

        return await withCheckedContinuation { (cont: CheckedContinuation<ToolResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-l", "-c", command]
                p.currentDirectoryURL = cwd
                var env = ProcessInfo.processInfo.environment
                env["TERM"] = "dumb"
                env["PAGER"] = "cat"
                env["GIT_PAGER"] = "cat"
                p.environment = env
                p.standardInput = FileHandle.nullDevice

                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                let out = DataBox(), err = DataBox()
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { out.append(d) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { err.append(d) }
                }

                do {
                    try p.run()
                } catch {
                    cont.resume(returning: ToolResult(output: "无法启动 shell：\(error.localizedDescription)", isError: true))
                    return
                }

                var timedOut = false
                let timer = DispatchWorkItem {
                    if p.isRunning { timedOut = true; p.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: timer)
                p.waitUntilExit()
                timer.cancel()

                // Give the readability handlers a moment to flush, then drain the rest.
                Thread.sleep(forTimeInterval: 0.05)
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.append(outPipe.fileHandleForReading.readDataToEndOfFileNonBlocking())
                err.append(errPipe.fileHandleForReading.readDataToEndOfFileNonBlocking())

                let stdout = String(decoding: out.value, as: UTF8.self)
                let stderr = String(decoding: err.value, as: UTF8.self)
                var text = ""
                if !stdout.isEmpty { text += stdout }
                if !stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + stderr }
                if timedOut { text += "\n[超时：\(timeout) 秒后已终止]" }
                text += "\n[exit \(p.terminationStatus)]"
                cont.resume(returning: ToolResult(output: ToolRunner.truncate(text),
                                                  isError: timedOut || p.terminationStatus != 0))
            }
        }
    }

    // MARK: - files

    private func readFile(_ args: [String: Any]) throws -> ToolResult {
        let url = resolve(try string(args, "path"))
        if let sid = SkillLibrary.skillID(forPath: url.path) { onSkillFile(sid, false) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return ToolResult(output: "不是 UTF-8 文本文件（\(data.count) 字节）", isError: true)
        }
        let lines = text.components(separatedBy: "\n")
        let start = max(1, intArg(args, "offset") ?? 1)
        let limit = max(1, intArg(args, "limit") ?? 2000)
        guard start <= lines.count else {
            return ToolResult(output: "offset 超出范围，文件共 \(lines.count) 行", isError: true)
        }
        let end = min(lines.count, start - 1 + limit)
        var body = lines[(start - 1)..<end].joined(separator: "\n")
        body = ToolRunner.truncate(body)
        let header = "[\(url.path) | 第 \(start)-\(end) 行，共 \(lines.count) 行]\n"
        return ToolResult(output: header + body)
    }

    private func writeFile(_ args: [String: Any]) throws -> ToolResult {
        let url = resolve(try string(args, "path"))
        defer { if url.path.hasPrefix(SkillLibrary.root.path + "/") { onSkillFile(SkillLibrary.skillID(forPath: url.path) ?? "", true) } }
        let content = try string(args, "content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ToolResult(output: "已写入 \(url.path)（\(content.utf8.count) 字节）")
    }

    private func editFile(_ args: [String: Any]) throws -> ToolResult {
        let url = resolve(try string(args, "path"))
        defer { if url.path.hasPrefix(SkillLibrary.root.path + "/") { onSkillFile(SkillLibrary.skillID(forPath: url.path) ?? "", true) } }
        let old = try string(args, "old_string")
        let new = try string(args, "new_string")
        let all = (args["replace_all"] as? Bool) ?? false
        guard !old.isEmpty else { return ToolResult(output: "old_string 不能为空", isError: true) }
        let text = try String(contentsOf: url, encoding: .utf8)
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { return ToolResult(output: "未找到 old_string", isError: true) }
        if count > 1 && !all {
            return ToolResult(output: "old_string 出现了 \(count) 次，请提供更多上下文或设置 replace_all", isError: true)
        }
        let updated: String
        if all {
            updated = text.replacingOccurrences(of: old, with: new)
        } else {
            let r = text.range(of: old)!
            updated = text.replacingCharacters(in: r, with: new)
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return ToolResult(output: "已修改 \(url.path)（替换 \(all ? count : 1) 处）")
    }

    private func listDir(_ args: [String: Any]) throws -> ToolResult {
        let url = resolve((args["path"] as? String) ?? ".")
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        var names: [String] = items.map { u in
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return u.lastPathComponent + (isDir ? "/" : "")
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        var out = "[\(url.path)，\(names.count) 项]\n"
        out += names.prefix(500).joined(separator: "\n")
        if names.count > 500 { out += "\n…（仅显示前 500 项）" }
        return ToolResult(output: out)
    }

    // MARK: - web

    private func webFetch(_ args: [String: Any]) async throws -> ToolResult {
        let raw = try string(args, "url")
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ToolResult(output: "URL 无效：\(raw)", isError: true)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let ctype = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var text = String(decoding: data, as: UTF8.self)
        if ctype.contains("html") || text.prefix(500).lowercased().contains("<html") {
            text = ToolRunner.htmlToText(text)
        }
        return ToolResult(output: ToolRunner.truncate("[HTTP \(status)] \(url.absoluteString)\n\n" + text),
                          isError: !(200..<400).contains(status))
    }

    static func htmlToText(_ html: String) -> String {
        var s = html
        func sub(_ pattern: String, _ with: String) {
            s = s.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
        }
        sub("<script[\\s\\S]*?</script>", "")
        sub("<style[\\s\\S]*?</style>", "")
        sub("<noscript[\\s\\S]*?</noscript>", "")
        sub("<!--[\\s\\S]*?-->", "")
        sub("<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>", "\n")
        sub("<li[^>]*>", "• ")
        sub("<[^>]+>", "")
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        sub("[ \\t]+", " ")
        sub("\\n\\s*\\n+", "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - memory

    private func memoryWrite(_ args: [String: Any]) throws -> ToolResult {
        let content = (args["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return ToolResult(output: "Error: Missing required 'content' parameter", isError: true) }
        let file = try MemoryStore.write(content)
        return ToolResult(output: "Memory saved to \(file) (\(content.count) chars)")
    }

    private func memoryGet(_ args: [String: Any]) -> ToolResult {
        ToolResult(output: MemoryStore.get(keywords: args["keywords"] as? String ?? "",
                                           scope: args["scope"] as? String ?? "all"))
    }
}

private extension FileHandle {
    /// Reads whatever is left without blocking forever if a background child keeps the pipe open.
    func readDataToEndOfFileNonBlocking() -> Data {
        let fd = fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var result = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            result.append(buf, count: n)
        }
        return result
    }
}
