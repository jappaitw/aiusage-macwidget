import Foundation

struct LimitsResult {
    var plan: String?
    var windows: [UsageWindow]
    /// 資料來源說明（面板顯示用），例如 "API"、"session log"
    var source = "API"
    /// 資料實際的時間；nil = 現在
    var capturedAt: Date?
}

enum UsageError: LocalizedError {
    case claudeNotSignedIn
    case claudeTokenExpired
    case claudeForbidden
    case codexNotFound
    case codexNoData
    case rateLimited
    case http(Int)
    case badResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotSignedIn: return "找不到 Claude Code 登入資訊（Claude 桌面版不提供用量資料，需要登入 Claude Code CLI）"
        case .claudeTokenExpired: return "Claude token 過期，開一下 Claude Code 就會自動更新"
        case .claudeForbidden: return "Claude 拒絕存取（沒有訂閱，或組織關閉了 OAuth）"
        case .codexNotFound: return "找不到 codex CLI"
        case .codexNoData: return "還沒有 Codex 用量資料，先用 Codex 跑一次對話"
        case .rateLimited: return "請求太頻繁（429），稍後自動重試"
        case .http(let code): return "HTTP \(code)"
        case .badResponse: return "回應格式看不懂（API 可能改版了）"
        case .message(let text): return text
        }
    }
}

/// 簡單的 JSON HTTP client
enum HTTP {
    static func json(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                     jsonBody: Any? = nil, form: [String: String]? = nil,
                     timeout: TimeInterval = 20) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let jsonBody {
            request.httpMethod = method == "GET" ? "POST" : method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        } else if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            request.httpBody = form.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }.joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 429 { throw UsageError.rateLimited }
            throw UsageError.http(code)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }
        return object
    }
}

enum Files {
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func appInstalled(_ names: [String]) -> Bool {
        let dirs = ["/Applications", Shell.home.appendingPathComponent("Applications").path]
        return names.contains { name in dirs.contains { exists("\($0)/\(name).app") } }
    }

    /// 找 CLI 執行檔：常見位置 → login shell
    static func executable(_ name: String, extra: [String] = []) -> URL? {
        let home = Shell.home.path
        let candidates = extra + [
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)", "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        for flags in ["-lc", "-ilc"] {
            if let out = Shell.run("/bin/zsh", [flags, "command -v \(name)"], timeout: 8), out.status == 0 {
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

enum Shell {
    struct Output {
        var status: Int32
        var stdout: Data
    }

    /// 同步執行一個指令，超時就砍掉
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10,
                    environment: [String: String]? = nil) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return Output(status: process.terminationStatus, stdout: data)
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

/// 掃 log 時用：同一個檔案沒變（mtime + size）就直接用上次解析的結果
final class FileParseCache<Record> {
    private struct Entry {
        var modified: Date
        var size: Int
        var records: [Record]
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func records(for url: URL, modified: Date, size: Int, parse: (URL) -> [Record]) -> [Record] {
        lock.lock()
        if let hit = entries[url.path], hit.modified == modified, hit.size == size {
            lock.unlock()
            return hit.records
        }
        lock.unlock()
        let parsed = parse(url)
        lock.lock()
        entries[url.path] = Entry(modified: modified, size: size, records: parsed)
        lock.unlock()
        return parsed
    }

    func prune(keeping paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        lock.unlock()
    }
}

enum LogFiles {
    struct Item {
        var url: URL
        var modified: Date
        var size: Int
    }

    /// 遞迴找出 dirs 底下最近修改過的 .jsonl
    static func jsonl(in dirs: [URL], modifiedAfter cutoff: Date) -> [Item] {
        var items: [Item] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= cutoff
                else { continue }
                items.append(Item(url: url, modified: modified, size: values.fileSize ?? 0))
            }
        }
        return items
    }

    /// 逐行讀，只把含有 needle 的行交給 handler（避免每行都 JSON parse）
    static func forEachLine(in url: URL, containing needles: [String], _ handler: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let needleBytes = needles.map { Data($0.utf8) }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            guard !line.isEmpty, needleBytes.allSatisfy({ dataContains(line, $0) }) else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                handler(obj)
            }
        }
    }

    private static func dataContains(_ haystack: Data, _ needle: Data) -> Bool {
        haystack.range(of: needle) != nil
    }
}

enum Days {
    /// 回傳最近 n 天（含今天）的每日 0 點，舊→新
    static func window(_ n: Int, now: Date = Date()) -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<n).compactMap { cal.date(byAdding: .day, value: $0 - (n - 1), to: today) }
    }

    static func fill(_ totals: [Date: Int], days: [Date]) -> [DayTokens] {
        days.map { DayTokens(day: $0, tokens: totals[$0] ?? 0) }
    }
}
