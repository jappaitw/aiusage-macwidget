import AppKit
import Foundation
import WidgetKit

enum Refresher {
    static func run(previous: UsageSnapshot) async -> UsageSnapshot {
        async let claudeLimits = capture { try await ClaudeUsageFetcher.fetch() }
        async let codexLimits = Task.detached(priority: .utility) {
            Swift.Result { try CodexUsageFetcher.fetchViaAppServer() }
        }.value
        async let claudeScan = Task.detached(priority: .utility) { LocalTokenScanner.scanClaude() }.value
        async let codexScan = Task.detached(priority: .utility) { LocalTokenScanner.scanCodex() }.value

        let now = Date()
        var claude = previous.claude
        let claudeResult = await claudeLimits
        switch claudeResult {
        case .success(let limits):
            claude.plan = limits.plan ?? claude.plan
            claude.windows = limits.windows
            claude.limitsUpdatedAt = now
            claude.limitsSource = "API"
            claude.error = nil
        case .failure(let error):
            // 抓失敗就保留上一次的數字，只標記錯誤
            claude.error = error.localizedDescription
        }
        let cScan = await claudeScan
        claude.daily = cScan.daily
        claude.models = cScan.models

        var codex = previous.codex
        let xScan = await codexScan
        let codexResult = await codexLimits
        switch codexResult {
        case .success(let limits):
            codex.plan = limits.plan ?? codex.plan
            codex.windows = limits.windows
            codex.limitsUpdatedAt = now
            codex.limitsSource = "app-server"
            codex.error = nil
        case .failure(let error):
            if let fromLog = xScan.latestLimits, let at = xScan.latestLimitsAt {
                codex.plan = fromLog.plan ?? codex.plan
                // log 裡的重置時間已過，代表那個視窗早就歸零了
                codex.windows = fromLog.windows.map { window in
                    var w = window
                    if let reset = w.resetsAt, reset < now { w.usedPercent = 0; w.resetsAt = nil }
                    return w
                }
                codex.limitsUpdatedAt = at
                codex.limitsSource = "session log"
                codex.error = nil
            } else {
                codex.error = error.localizedDescription
            }
        }
        codex.daily = xScan.daily
        codex.models = xScan.models

        return UsageSnapshot(generatedAt: now, claude: claude, codex: codex)
    }

    private static func capture<T>(_ operation: () async throws -> T) async -> Swift.Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}

@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private var lastWidgetSignature: String?
    private var lastWidgetReload = Date.distantPast
    private var started = false

    /// 每 5 分鐘抓一次（Claude API 太頻繁會 429）
    let interval: TimeInterval = 300

    private init() {
        snapshot = SharedStore.load() ?? .empty
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in UsageModel.shared.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in UsageModel.shared.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let previous = snapshot
        Task {
            let next = await Refresher.run(previous: previous)
            snapshot = next
            isRefreshing = false
            do { try SharedStore.save(next) } catch { NSLog("AIUsage: 寫入 App Group 失敗：\(error)") }
            reloadWidgetIfNeeded(next)
        }
    }

    /// WidgetKit 對背景 reload 有每日額度，數字沒變就不浪費（最多 30 分鐘強制一次）
    private func reloadWidgetIfNeeded(_ s: UsageSnapshot) {
        let signature = [s.claude, s.codex].map { p in
            p.windows.map { "\($0.label)=\(Int($0.usedPercent.rounded()))" }.joined(separator: ",")
                + "|e=\(p.error ?? "")|t=\(p.todayTokens / 200_000)"
        }.joined(separator: "#")
        let now = Date()
        guard signature != lastWidgetSignature || now.timeIntervalSince(lastWidgetReload) > 1800 else { return }
        lastWidgetSignature = signature
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    var menuBarTitle: String {
        func short(_ p: ProviderSnapshot) -> String {
            p.windows.first.map { Format.percent($0.usedPercent) } ?? "–"
        }
        return "C \(short(snapshot.claude))  X \(short(snapshot.codex))"
    }
}
