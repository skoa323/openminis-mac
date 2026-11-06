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
    let memoryFile: URL
    /// Called before running a shell command. Return false to reject.
    let approve: (String) async -> Bool

    init(workspace: URL, memoryFile: URL, approve: @escaping (String) async -> Bool) {
        self.workspace = workspace
        self.memoryFile = memoryFile
        self.approve = approve
    }

    static let maxOutput = 30_000

    // MARK: - Specs

    static var specs: [ToolSpec] {
        func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
        func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
        func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }

        return [
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
            ToolSpec(name: "memory_write",
                     description: "把值得长期记住的信息（用户偏好、项目约定等）追加到记忆文件，之后每次对话都会带上。",
                     parameters: obj(["content": str("要记住的内容，简洁")], ["content"])),
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
            case "memory_write": return try memoryWrite(args)
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
        let content = try string(args, "content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ToolResult(output: "已写入 \(url.path)（\(content.utf8.count) 字节）")
    }

    private func editFile(_ args: [String: Any]) throws -> ToolResult {
        let url = resolve(try string(args, "path"))
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
        let content = try string(args, "content").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return ToolResult(output: "内容为空", isError: true) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let entry = "\n- [\(f.string(from: Date()))] \(content)\n"
        let fm = FileManager.default
        try fm.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: memoryFile.path) {
            try "# OpenMinis 记忆\n".write(to: memoryFile, atomically: true, encoding: .utf8)
        }
        let h = try FileHandle(forWritingTo: memoryFile)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(entry.utf8))
        return ToolResult(output: "已记住。")
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
