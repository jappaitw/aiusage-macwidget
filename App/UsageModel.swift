import AppKit
import Foundation
import WidgetKit

enum Refresher {
    /// 偵測這台 Mac 上有的服務，並行抓取，依 ProviderRegistry 的順序回傳
    static func run(previous: [String: ProviderSnapshot]) async -> [ProviderSnapshot] {
        let detected = await Task.detached(priority: .utility) {
            ProviderRegistry.all.filter { $0.isDetected() }
        }.value

        return await withTaskGroup(of: (Int, ProviderSnapshot).self) { group in
            for (index, provider) in detected.enumerated() {
                let prior = previous[provider.id] ?? ProviderSnapshot(id: provider.id, name: provider.name)
                group.addTask { (index, await refresh(provider, previous: prior)) }
            }
            var results: [(Int, ProviderSnapshot)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private static func refresh(_ provider: any UsageProvider, previous: ProviderSnapshot) async -> ProviderSnapshot {
        var snapshot = previous
        snapshot.name = provider.name
        async let scan = Task.detached(priority: .utility) { provider.scanTokens() }.value
        do {
            let limits = try await provider.fetchLimits()
            snapshot.plan = limits.plan ?? snapshot.plan
            snapshot.windows = limits.windows
            snapshot.limitsUpdatedAt = limits.capturedAt ?? Date()
            snapshot.limitsSource = limits.source
            snapshot.error = nil
        } catch {
            // 抓失敗就保留上一次的數字，只標記錯誤
            snapshot.error = error.localizedDescription
        }
        let scanned = await scan
        if let tokens = scanned {
            snapshot.daily = tokens.daily
            snapshot.models = tokens.models
        }
        return snapshot
    }
}

@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    /// 偵測到的全部服務（含隱藏的）
    @Published private(set) var providers: [ProviderSnapshot]
    @Published private(set) var lastUpdated: Date
    @Published private(set) var isRefreshing = false
    @Published private(set) var hidden: Set<String>

    private var timer: Timer?
    private var lastWidgetSignature: String?
    private var lastWidgetReload = Date.distantPast
    private var started = false
    private static let hiddenKey = "hiddenProviders"

    /// 每 5 分鐘抓一次（太頻繁 Claude 會回 429）
    let interval: TimeInterval = 300

    private init() {
        let stored = SharedStore.load()
        providers = stored?.providers ?? []
        lastUpdated = stored?.generatedAt ?? .distantPast
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    /// 給 widget／選單列看的（已排除隱藏的）
    var snapshot: UsageSnapshot {
        UsageSnapshot(generatedAt: lastUpdated, providers: providers.filter { !hidden.contains($0.id) })
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
        let previous = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Task {
            let next = await Refresher.run(previous: previous)
            providers = next
            lastUpdated = Date()
            isRefreshing = false
            publish(force: false)
        }
    }

    func setVisible(_ id: String, _ visible: Bool) {
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        UserDefaults.standard.set(Array(hidden).sorted(), forKey: Self.hiddenKey)
        publish(force: true)
    }

    /// 寫入 App Group；WidgetKit 對背景 reload 有每日額度，數字沒變就不 reload（最多 30 分鐘強制一次）
    private func publish(force: Bool) {
        let current = snapshot
        do { try SharedStore.save(current) } catch { NSLog("AIUsage: 寫入 App Group 失敗：\(error)") }
        let signature = current.providers.map { p in
            "\(p.id):" + p.windows.map { "\($0.label)=\(Int($0.usedPercent.rounded()))" }.joined(separator: ",")
                + "|e=\(p.error ?? "")|t=\(p.todayTokens / 200_000)"
        }.joined(separator: "#")
        let now = Date()
        guard force || signature != lastWidgetSignature || now.timeIntervalSince(lastWidgetReload) > 1800 else { return }
        lastWidgetSignature = signature
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 選單列縮寫：名字第一個字母會撞（Claude/Codex/Cursor/Copilot 都是 C），改用固定表
    private static let menuInitials = [
        "claude": "C", "codex": "X", "cursor": "Cu",
        "copilot": "Cp", "gemini": "G", "antigravity": "A",
    ]

    var menuBarTitle: String {
        let shown = snapshot.providers.prefix(2)
        if shown.isEmpty { return "AI –" }
        return shown.map { p in
            let initial = Self.menuInitials[p.id] ?? String(p.name.prefix(1))
            return "\(initial) " + (p.windows.first.map { Format.percent($0.usedPercent) } ?? "–")
        }.joined(separator: "  ")
    }
}
