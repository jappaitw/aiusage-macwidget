import Foundation

struct LimitsResult {
    var plan: String?
    var windows: [UsageWindow]
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

    var errorDescription: String? {
        switch self {
        case .claudeNotSignedIn: return "找不到 Claude Code 登入資訊，先在終端機跑一次 claude 登入"
        case .claudeTokenExpired: return "Claude token 過期，開一下 Claude Code 就會自動更新"
        case .claudeForbidden: return "Claude 拒絕存取（沒有訂閱，或組織關閉了 OAuth）"
        case .codexNotFound: return "找不到 codex CLI"
        case .codexNoData: return "還沒有 Codex 用量資料，先用 Codex 跑一次對話"
        case .rateLimited: return "請求太頻繁（429），稍後自動重試"
        case .http(let code): return "HTTP \(code)"
        case .badResponse: return "回應格式看不懂（API 可能改版了）"
        }
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
