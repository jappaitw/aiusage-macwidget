import Foundation

/// Codex 額度：
/// 1. 優先問 `codex app-server`（JSON-RPC over stdio 的 account/rateLimits/read，Codex 自己管登入，資料是即時的）
/// 2. 不行的話用 ~/.codex/sessions 裡最後一筆 token_count 事件的 rate_limits（只跟最後一次用 Codex 一樣新）
enum CodexUsageFetcher {
    static func fetchViaAppServer(timeout: TimeInterval = 20) throws -> LimitsResult {
        guard let codex = locateCodex() else { throw UsageError.codexNotFound }
        var lastError: Error = UsageError.codexNoData
        // 新舊版本旗標可能不同，兩種都試
        for args in [["app-server", "--stdio"], ["app-server"]] {
            do {
                let result = try requestRateLimits(executable: codex, arguments: args, timeout: timeout)
                return try parseAppServer(result)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - app-server

    private static func requestRateLimits(executable: URL, arguments: [String],
                                          timeout: TimeInterval) throws -> [String: Any] {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // GUI app 的 PATH 很短；codex 若是 npm 裝的 node script 需要找得到 node
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let reader = JSONRPCReader()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            reader.feed(chunk)
        }
        process.terminationHandler = { _ in reader.feed(Data()) }

        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let deadline = Date().addingTimeInterval(timeout)
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }

        try send(["method": "initialize", "id": 1,
                  "params": ["clientInfo": ["name": "aiusage_widget", "title": "AI Usage", "version": "1.0"]]])
        guard let initReply = reader.wait(for: 1, until: deadline), initReply["error"] == nil else {
            throw UsageError.codexNoData
        }
        try send(["method": "initialized"])
        try send(["method": "account/rateLimits/read", "id": 2])
        guard let reply = reader.wait(for: 2, until: deadline), reply["error"] == nil,
              let result = reply["result"] as? [String: Any] else {
            throw UsageError.codexNoData
        }
        return result
    }

    static func parseAppServer(_ result: [String: Any]) throws -> LimitsResult {
        guard let aggregate = result["rateLimits"] as? [String: Any] else { throw UsageError.badResponse }
        var windows = appServerWindows(aggregate, scope: nil)
        let aggregateID = aggregate["limitId"] as? String ?? "codex"

        // rateLimitsByLimitId：其他額外的額度（例如特定模型）
        var extras: [[String: Any]] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            for (key, value) in byID.sorted(by: { $0.key < $1.key }) {
                guard var item = value as? [String: Any] else { continue }
                item["limitId"] = item["limitId"] ?? key
                extras.append(item)
            }
        } else if let list = result["rateLimitsByLimitId"] as? [[String: Any]] {
            extras = list
        }
        for item in extras {
            let id = item["limitId"] as? String
            guard let id, id != aggregateID, id != "codex" else { continue }
            windows += appServerWindows(item, scope: item["limitName"] as? String ?? id)
        }
        if windows.isEmpty { throw UsageError.codexNoData }
        let plan = result["planType"] as? String ?? aggregate["planType"] as? String
        return LimitsResult(plan: plan, windows: windows)
    }

    private static func appServerWindows(_ snapshot: [String: Any], scope: String?) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { kind in
            guard let item = snapshot[kind] as? [String: Any],
                  let used = JSONValue.number(item["usedPercent"]) else { return nil }
            let label = windowLabel(minutes: JSONValue.int(item["windowDurationMins"]), fallback: kind)
            return UsageWindow(label: scope.map { "\(label) · \($0)" } ?? label,
                               usedPercent: used, resetsAt: DateParsing.unix(item["resetsAt"]))
        }
    }

    // MARK: - session log 裡的 rate_limits

    /// rate_limits: { primary: {used_percent, window_minutes, resets_at | resets_in_seconds}, secondary: …, plan_type }
    static func parseLogRateLimits(_ limits: [String: Any], eventTime: Date) -> LimitsResult? {
        let windows: [UsageWindow] = ["primary", "secondary"].compactMap { kind in
            guard let item = limits[kind] as? [String: Any],
                  let used = JSONValue.number(item["used_percent"]) else { return nil }
            var reset = DateParsing.unix(item["resets_at"])
            if reset == nil, let seconds = JSONValue.number(item["resets_in_seconds"]) {
                reset = eventTime.addingTimeInterval(seconds)
            }
            return UsageWindow(label: windowLabel(minutes: JSONValue.int(item["window_minutes"]), fallback: kind),
                               usedPercent: used, resetsAt: reset)
        }
        return windows.isEmpty ? nil : LimitsResult(plan: limits["plan_type"] as? String, windows: windows)
    }

    static func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback == "primary" ? "5 小時" : "每週" }
        switch minutes {
        case 270...330: return "5 小時"
        case 1300...1600: return "每日"
        case 9000...11000: return "每週"
        case 40000...46000: return "每月"
        default: return minutes % 60 == 0 ? "\(minutes / 60) 小時" : "\(minutes) 分鐘"
        }
    }

    // MARK: - 找 codex 執行檔

    static func locateCodex() -> URL? {
        let home = Shell.home.path
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex",
            "\(home)/.volta/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        // 最後問 login shell（nvm / asdf 之類）
        for flags in ["-lc", "-ilc"] {
            if let out = Shell.run("/bin/zsh", [flags, "command -v codex"], timeout: 8), out.status == 0 {
                let path = String(decoding: out.stdout, as: UTF8.self)
                    .split(separator: "\n").last.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }
}

/// 收 stdout、切行、依 id 存 JSON-RPC 回應
final class JSONRPCReader {
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var closed = false
    private let condition = NSCondition()

    func feed(_ chunk: Data) {
        condition.lock()
        defer { condition.unlock() }
        if chunk.isEmpty {
            closed = true
            condition.broadcast()
            return
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let id = JSONValue.int(obj["id"]), obj["method"] == nil {
                responses[id] = obj
            }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        condition.broadcast()
    }

    func wait(for id: Int, until deadline: Date) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil && !closed {
            if !condition.wait(until: deadline) { break }
        }
        return responses[id]
    }
}
