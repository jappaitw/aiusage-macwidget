import Foundation

/// 從本機 log 算 token 用量（全部在本機算，不會傳出去）
enum LocalTokenScanner {
    struct Result {
        var daily: [DayTokens]
        var models: [ModelTokens]
        /// Codex 專用：log 裡最新一筆 rate_limits
        var latestLimits: LimitsResult?
        var latestLimitsAt: Date?
    }

    // MARK: - Claude Code：~/.claude/projects/**/*.jsonl

    private struct ClaudeRecord {
        var key: String?
        var time: Date
        var model: String?
        var tokens: Int
    }

    private static let claudeCache = FileParseCache<ClaudeRecord>()

    static func scanClaude(days: Int = 7, now: Date = Date()) -> Result {
        let dayList = Days.window(days, now: now)
        guard let start = dayList.first else { return Result(daily: [], models: []) }
        let dirs = [Shell.home.appendingPathComponent(".claude/projects"),
                    Shell.home.appendingPathComponent(".config/claude/projects")]
        let files = LogFiles.jsonl(in: dirs, modifiedAfter: start)
        claudeCache.prune(keeping: Set(files.map { $0.url.path }))

        var byDay: [Date: Int] = [:]
        var byModel: [String: Int] = [:]
        var seen = Set<String>()
        let cal = Calendar.current

        for file in files {
            let records = claudeCache.records(for: file.url, modified: file.modified, size: file.size, parse: parseClaudeFile)
            for record in records where record.time >= start {
                // 同一則回應可能出現在多個檔案（resume session），用 message.id + requestId 去重
                if let key = record.key, !seen.insert(key).inserted { continue }
                byDay[cal.startOfDay(for: record.time), default: 0] += record.tokens
                if let model = record.model { byModel[claudeModelName(model), default: 0] += record.tokens }
            }
        }
        return Result(daily: Days.fill(byDay, days: dayList), models: sortedModels(byModel))
    }

    private static func parseClaudeFile(_ url: URL) -> [ClaudeRecord] {
        var records: [ClaudeRecord] = []
        LogFiles.forEachLine(in: url, containing: ["\"usage\"", "\"assistant\""]) { obj in
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let time = DateParsing.iso(obj["timestamp"] as? String) else { return }
            let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + (JSONValue.int(usage[$1]) ?? 0) }
            guard tokens > 0 else { return }
            let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
            let key = (message["id"] as? String).map { "\($0):\(obj["requestId"] as? String ?? "")" }
            records.append(ClaudeRecord(key: key, time: time, model: model, tokens: tokens))
        }
        return records
    }

    /// "claude-sonnet-4-5-20250929" → "Sonnet 4.5"、"claude-opus-4-7" → "Opus 4.7"
    static func claudeModelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    // MARK: - Codex：~/.codex/sessions/**/rollout-*.jsonl

    private enum CodexRecord {
        case tokens(time: Date, model: String?, tokens: Int)
        case limits(time: Date, value: [String: Any])
    }

    private static let codexCache = FileParseCache<CodexRecord>()

    static func scanCodex(days: Int = 7, now: Date = Date()) -> Result {
        let dayList = Days.window(days, now: now)
        guard let start = dayList.first else { return Result(daily: [], models: []) }
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Shell.home.appendingPathComponent(".codex")
        let dirs = [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")]
        let files = LogFiles.jsonl(in: dirs, modifiedAfter: start)
        codexCache.prune(keeping: Set(files.map { $0.url.path }))

        var byDay: [Date: Int] = [:]
        var byModel: [String: Int] = [:]
        var latest: (time: Date, value: [String: Any])?
        let cal = Calendar.current

        for file in files {
            for record in codexCache.records(for: file.url, modified: file.modified, size: file.size, parse: parseCodexFile) {
                switch record {
                case let .tokens(time, model, tokens):
                    guard time >= start else { continue }
                    byDay[cal.startOfDay(for: time), default: 0] += tokens
                    byModel[model ?? "codex", default: 0] += tokens
                case let .limits(time, value):
                    if latest == nil || time > latest!.time { latest = (time, value) }
                }
            }
        }

        var result = Result(daily: Days.fill(byDay, days: dayList), models: sortedModels(byModel))
        if let latest, let limits = CodexUsageFetcher.parseLogRateLimits(latest.value, eventTime: latest.time) {
            result.latestLimits = limits
            result.latestLimitsAt = latest.time
        }
        return result
    }

    private static func parseCodexFile(_ url: URL) -> [CodexRecord] {
        var records: [CodexRecord] = []
        var model: String?
        var previousTotal = 0
        LogFiles.forEachLine(in: url, containing: ["\"payload\""]) { obj in
            guard let payload = obj["payload"] as? [String: Any] else { return }
            if obj["type"] as? String == "turn_context" {
                model = (payload["model"] as? String) ?? model
                return
            }
            guard payload["type"] as? String == "token_count",
                  let time = DateParsing.iso(obj["timestamp"] as? String) else { return }

            if let info = payload["info"] as? [String: Any],
               let total = codexTotal(info["total_token_usage"]) {
                // total_token_usage 是累計值：取差值；同一個值重複送就略過；歸零（新 session 片段）就用 last_token_usage
                var delta = 0
                if total > previousTotal {
                    delta = total - previousTotal
                } else if total < previousTotal {
                    delta = codexTotal(info["last_token_usage"]) ?? total
                }
                previousTotal = total
                if delta > 0 { records.append(.tokens(time: time, model: model, tokens: delta)) }
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                records.append(.limits(time: time, value: limits))
            }
        }
        return records
    }

    /// total_tokens，沒有的話 input + output
    private static func codexTotal(_ value: Any?) -> Int? {
        guard let usage = value as? [String: Any] else { return nil }
        if let total = JSONValue.int(usage["total_tokens"]) { return total }
        let input = JSONValue.int(usage["input_tokens"]), output = JSONValue.int(usage["output_tokens"])
        if input == nil && output == nil { return nil }
        return (input ?? 0) + (output ?? 0)
    }

    private static func sortedModels(_ totals: [String: Int]) -> [ModelTokens] {
        totals.filter { $0.value > 0 }
            .map { ModelTokens(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
    }
}
