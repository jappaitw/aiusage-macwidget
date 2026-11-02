import Foundation

/// 每個 AI 服務實作這個 protocol，加新服務只要寫一個 struct 並放進 ProviderRegistry.all
protocol UsageProvider: Sendable {
    var id: String { get }
    var name: String { get }
    /// 快速偵測：這台 Mac 有沒有裝／登入過（只看檔案、不打網路）
    func isDetected() -> Bool
    /// 抓額度
    func fetchLimits() async throws -> LimitsResult
    /// 本機 token 統計；沒有本機 log 的服務回傳 nil
    func scanTokens() -> LocalTokenScanner.Result?
}

extension UsageProvider {
    func scanTokens() -> LocalTokenScanner.Result? { nil }
}

enum ProviderRegistry {
    /// 預設顯示順序
    static let all: [any UsageProvider] = [
        ClaudeProvider(), CodexProvider(), CursorProvider(),
        CopilotProvider(), GeminiProvider(), AntigravityProvider(),
    ]

    static func provider(id: String) -> (any UsageProvider)? { all.first { $0.id == id } }
}

// MARK: - Claude Code

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let name = "Claude"

    func isDetected() -> Bool {
        Files.exists(Shell.home.appendingPathComponent(".claude").path) || Files.appInstalled(["Claude"])
    }

    func fetchLimits() async throws -> LimitsResult { try await ClaudeUsageFetcher.fetch() }

    func scanTokens() -> LocalTokenScanner.Result? { LocalTokenScanner.scanClaude() }
}

// MARK: - Codex

struct CodexProvider: UsageProvider {
    let id = "codex"
    let name = "Codex"

    func isDetected() -> Bool {
        Files.exists(Shell.home.appendingPathComponent(".codex").path) || Files.appInstalled(["Codex"])
    }

    func fetchLimits() async throws -> LimitsResult {
        do {
            var live = try await Task.detached(priority: .utility) {
                try CodexUsageFetcher.fetchViaAppServer()
            }.value
            live.source = "app-server"
            return live
        } catch {
            // app-server 不行就用 session log 裡最新的 rate_limits
            let scan = LocalTokenScanner.scanCodex()
            guard var fromLog = scan.latestLimits, let at = scan.latestLimitsAt else { throw error }
            let now = Date()
            fromLog.windows = fromLog.windows.map { window in
                var w = window
                // log 裡的重置時間已過 → 那個視窗早就歸零了
                if let reset = w.resetsAt, reset < now { w.usedPercent = 0; w.resetsAt = nil }
                return w
            }
            fromLog.source = "session log"
            fromLog.capturedAt = at
            return fromLog
        }
    }

    func scanTokens() -> LocalTokenScanner.Result? { LocalTokenScanner.scanCodex() }
}
