import Foundation

/// 一個額度視窗（5 小時、每週、每週·某模型…）
struct UsageWindow: Codable, Hashable, Identifiable {
    var id: String { label }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
}

struct DayTokens: Codable, Hashable, Identifiable {
    var id: Date { day }
    var day: Date
    var tokens: Int
}

struct ModelTokens: Codable, Hashable, Identifiable {
    var id: String { model }
    var model: String
    var tokens: Int
}

struct ProviderSnapshot: Codable, Hashable {
    var plan: String?
    var windows: [UsageWindow]
    /// 額度資料實際取得的時間（Codex 從 session log 讀時會是該事件的時間）
    var limitsUpdatedAt: Date?
    var limitsSource: String?
    var error: String?
    /// 最近 7 天，舊→新，最後一筆是今天
    var daily: [DayTokens]
    /// 最近 7 天各模型 token，大→小
    var models: [ModelTokens]

    init(plan: String? = nil, windows: [UsageWindow] = [], limitsUpdatedAt: Date? = nil,
         limitsSource: String? = nil, error: String? = nil, daily: [DayTokens] = [], models: [ModelTokens] = []) {
        self.plan = plan
        self.windows = windows
        self.limitsUpdatedAt = limitsUpdatedAt
        self.limitsSource = limitsSource
        self.error = error
        self.daily = daily
        self.models = models
    }

    var todayTokens: Int {
        guard let last = daily.last, Calendar.current.isDateInToday(last.day) else { return 0 }
        return last.tokens
    }

    var weekTokens: Int { daily.reduce(0) { $0 + $1.tokens } }
}

struct UsageSnapshot: Codable, Hashable {
    var generatedAt: Date
    var claude: ProviderSnapshot
    var codex: ProviderSnapshot

    static let empty = UsageSnapshot(
        generatedAt: .distantPast,
        claude: ProviderSnapshot(error: "開啟 AI Usage app 開始抓資料"),
        codex: ProviderSnapshot(error: "開啟 AI Usage app 開始抓資料"))

    /// 小工具圖庫預覽用的假資料
    static var preview: UsageSnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func days(_ values: [Int]) -> [DayTokens] {
            values.enumerated().map { i, v in
                DayTokens(day: cal.date(byAdding: .day, value: i - (values.count - 1), to: today)!, tokens: v)
            }
        }
        return UsageSnapshot(
            generatedAt: Date(),
            claude: ProviderSnapshot(
                plan: "Max 5x",
                windows: [
                    UsageWindow(label: "5 小時", usedPercent: 42, resetsAt: Date().addingTimeInterval(2 * 3600)),
                    UsageWindow(label: "每週", usedPercent: 63, resetsAt: Date().addingTimeInterval(3 * 86400)),
                    UsageWindow(label: "每週 · Opus", usedPercent: 21, resetsAt: Date().addingTimeInterval(3 * 86400)),
                ],
                limitsUpdatedAt: Date(), limitsSource: "API",
                daily: days([8_200_000, 12_400_000, 5_100_000, 0, 9_800_000, 15_300_000, 6_700_000]),
                models: [ModelTokens(model: "Opus 4.7", tokens: 41_000_000), ModelTokens(model: "Sonnet 4.6", tokens: 16_500_000)]),
            codex: ProviderSnapshot(
                plan: "Plus",
                windows: [
                    UsageWindow(label: "5 小時", usedPercent: 18, resetsAt: Date().addingTimeInterval(4 * 3600)),
                    UsageWindow(label: "每週", usedPercent: 77, resetsAt: Date().addingTimeInterval(2 * 86400)),
                ],
                limitsUpdatedAt: Date(), limitsSource: "app-server",
                daily: days([1_200_000, 3_400_000, 2_100_000, 900_000, 4_800_000, 2_300_000, 1_700_000]),
                models: [ModelTokens(model: "gpt-5.1-codex", tokens: 16_400_000)]))
    }
}

// MARK: - 格式化

enum Format {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", d / 1_000_000_000)
        case 1_000_000...: return String(format: d >= 100_000_000 ? "%.0fM" : "%.1fM", d / 1_000_000)
        case 1_000...: return String(format: "%.0fK", d / 1_000)
        default: return "\(n)"
        }
    }

    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    /// "default_claude_max_20x" → "Max 20x"、"plus" → "Plus"
    static func plan(_ raw: String?) -> String? {
        guard var s = raw, !s.isEmpty else { return nil }
        for prefix in ["default_claude_", "claude_"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        let words = s.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { w -> String in
            w.first.map { String($0).uppercased() + w.dropFirst() } ?? ""
        }
        return words.joined(separator: " ")
    }
}

// MARK: - 日期解析

enum DateParsing {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    /// JSON 裡的數字（秒或毫秒的 unix time 都接受）
    static func unix(_ value: Any?) -> Date? {
        guard let n = JSONValue.number(value), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }
}

enum JSONValue {
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func int(_ value: Any?) -> Int? { number(value).map { Int($0) } }
}
