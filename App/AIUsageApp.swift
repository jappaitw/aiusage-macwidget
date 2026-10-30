import AppKit
import ServiceManagement
import SwiftUI

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = UsageModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Text(model.menuBarTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 寫入已關閉的 pipe（codex 提早結束）時不要整個 app 被 SIGPIPE 砍掉
        signal(SIGPIPE, SIG_IGN)
        Task { @MainActor in UsageModel.shared.start() }
    }

    /// 點 widget 會開 aiusage://refresh
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "aiusage" }) else { return }
        Task { @MainActor in UsageModel.shared.refresh() }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: UsageModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageDashboard(snapshot: model.snapshot)

            VStack(alignment: .leading, spacing: 4) {
                StatusLine(name: "Claude", snapshot: model.snapshot.claude)
                StatusLine(name: "Codex", snapshot: model.snapshot.codex)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    model.refresh()
                } label: {
                    Label(model.isRefreshing ? "更新中…" : "立即更新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)

                Spacer()

                Toggle("登入時啟動", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Button("結束") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// 面板下方的資料來源／錯誤說明
private struct StatusLine: View {
    var name: String
    var snapshot: ProviderSnapshot

    var body: some View {
        Group {
            if let error = snapshot.error {
                Label("\(name)：\(error)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let at = snapshot.limitsUpdatedAt {
                (Text("\(name) 額度來源：\(snapshot.limitsSource ?? "–")，取得於 ") + Text(at, style: .relative) + Text(" 前"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(2)
    }
}
