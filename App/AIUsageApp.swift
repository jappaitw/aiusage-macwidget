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
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageDashboard(snapshot: model.snapshot, maxProviders: 12, maxWindows: 4, showModels: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.snapshot.providers) { provider in
                    StatusLine(provider: provider)
                }
            }

            DisclosureGroup("顯示的服務", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.providers.isEmpty {
                        Text("還沒偵測到任何服務").foregroundStyle(.secondary)
                    }
                    ForEach(model.providers) { provider in
                        Toggle(isOn: Binding(
                            get: { !model.hidden.contains(provider.id) },
                            set: { model.setVisible(provider.id, $0) }
                        )) {
                            HStack(spacing: 5) {
                                Circle().fill(Brand.color(for: provider.id)).frame(width: 7, height: 7)
                                Text(provider.name)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text("支援：Claude Code、Codex、Cursor、GitHub Copilot、Gemini CLI、Antigravity。偵測到登入資料就會自動出現。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
            .font(.callout)

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
        .frame(width: 400)
    }
}

/// 面板下方的資料來源／錯誤說明
private struct StatusLine: View {
    var provider: ProviderSnapshot

    var body: some View {
        Group {
            if let error = provider.error {
                Label("\(provider.name)：\(error)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let at = provider.limitsUpdatedAt {
                (Text("\(provider.name)：\(provider.limitsSource ?? "–")，") + Text(at, style: .relative) + Text(" 前"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(2)
    }
}
