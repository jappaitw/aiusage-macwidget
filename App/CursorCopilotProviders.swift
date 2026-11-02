import Foundation

// MARK: - Cursor

/// Cursor：讀 Cursor（IDE 或 CLI）已存的 access token，打 Dashboard API（非公開）
struct CursorProvider: UsageProvider {
    let id = "cursor"
    let name = "Cursor"

    private var stateDB: URL {
        Shell.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
    private var cliAuth: URL { Shell.home.appendingPathComponent(".config/cursor/auth.json") }

    func isDetected() -> Bool {
        Files.exists(stateDB.path) || Files.exists(cliAuth.path) || Files.appInstalled(["Cursor"])
    }

    private func accessToken() -> String? {
        if let token = Files.json(cliAuth)?["accessToken"] as? String, !token.isEmpty { return token }
        guard Files.exists(stateDB.path),
              let out = Shell.run("/usr/bin/sqlite3",
                                  ["-readonly", stateDB.path,
                                   "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"],
                                  timeout: 10),
              out.status == 0 else { return nil }
        let token = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func fetchLimits() async throws -> LimitsResult {
        guard let token = accessToken() else { throw UsageError.message("Cursor 尚未登入") }
        let base = "https://api2.cursor.sh/aiserver.v1.DashboardService/"
        let headers = ["Authorization": "Bearer \(token)", "Connect-Protocol-Version": "1"]

        let usage: [String: Any]
        do {
            usage = try await HTTP.json(URL(string: base + "GetCurrentPeriodUsage")!, method: "POST",
                                        headers: headers, jsonBody: [String: Any]())
        } catch UsageError.http(let code) where code == 401 || code == 403 {
            throw UsageError.message("Cursor 登入過期，開一下 Cursor 就會更新")
        }
        let planInfo = try? await HTTP.json(URL(string: base + "GetPlanInfo")!, method: "POST",
                                            headers: headers, jsonBody: [String: Any]())

        guard let planUsage = usage["planUsage"] as? [String: Any],
              let total = JSONValue.number(planUsage["totalPercentUsed"]) else { throw UsageError.badResponse }
        let reset = DateParsing.unix(usage["billingCycleEnd"])
        var windows = [UsageWindow(label: "本期", usedPercent: total, resetsAt: reset)]
        if let auto = JSONValue.number(planUsage["autoPercentUsed"]) {
            windows.append(UsageWindow(label: "Auto", usedPercent: auto, resetsAt: reset))
        }
        if let api = JSONValue.number(planUsage["apiPercentUsed"]) {
            windows.append(UsageWindow(label: "API 模型", usedPercent: api, resetsAt: reset))
        }
        let plan = (planInfo?["planInfo"] as? [String: Any])?["planName"] as? String
        return LimitsResult(plan: plan, windows: windows)
    }
}

// MARK: - GitHub Copilot

/// GitHub Copilot：讀 Copilot 外掛／CLI 存在 ~/.config/github-copilot 的 OAuth token，
/// 打 copilot_internal/user（VS Code 顯示額度用的同一支，非公開）
struct CopilotProvider: UsageProvider {
    let id = "copilot"
    let name = "Copilot"

    private var configDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("github-copilot")
        }
        return Shell.home.appendingPathComponent(".config/github-copilot")
    }

    func isDetected() -> Bool {
        ["apps.json", "hosts.json"].contains { Files.exists(configDir.appendingPathComponent($0).path) }
    }

    private func oauthToken() -> String? {
        for file in ["apps.json", "hosts.json"] {
            guard let root = Files.json(configDir.appendingPathComponent(file)) else { continue }
            for (key, value) in root.sorted(by: { $0.key < $1.key }) where key.hasPrefix("github.com") {
                if let token = (value as? [String: Any])?["oauth_token"] as? String, !token.isEmpty { return token }
            }
        }
        return nil
    }

    func fetchLimits() async throws -> LimitsResult {
        guard let token = oauthToken() else { throw UsageError.message("Copilot 尚未登入") }
        let user: [String: Any]
        do {
            user = try await HTTP.json(URL(string: "https://api.github.com/copilot_internal/user")!, headers: [
                "Authorization": "token \(token)",
                "Editor-Version": "vscode/1.99.0",
                "Editor-Plugin-Version": "copilot-chat/0.26.7",
                "User-Agent": "GitHubCopilotChat/0.26.7",
                "X-GitHub-Api-Version": "2025-04-01",
            ])
        } catch UsageError.http(let code) where code == 401 || code == 403 || code == 404 {
            throw UsageError.message("Copilot token 失效，或這個帳號沒有 Copilot")
        }

        let reset = Self.parseResetDate(user["quota_reset_date_utc"] as? String)
            ?? Self.parseResetDate(user["quota_reset_date"] as? String)
        let snapshots = user["quota_snapshots"] as? [String: Any] ?? [:]
        let kinds: [(key: String, label: String)] = [
            ("premium_interactions", "Premium 請求"), ("chat", "Chat"), ("completions", "補全"),
        ]
        var windows: [UsageWindow] = []
        for kind in kinds {
            guard let quota = snapshots[kind.key] as? [String: Any], quota["unlimited"] as? Bool != true else { continue }
            var used: Double?
            if let remaining = JSONValue.number(quota["percent_remaining"]) {
                used = 100 - remaining
            } else if let entitlement = JSONValue.number(quota["entitlement"]), entitlement > 0,
                      let remaining = JSONValue.number(quota["remaining"]) {
                used = (entitlement - remaining) / entitlement * 100
            }
            if let used {
                windows.append(UsageWindow(label: kind.label, usedPercent: min(max(used, 0), 100), resetsAt: reset))
            }
        }
        let plan = user["copilot_plan"] as? String
        if windows.isEmpty {
            throw UsageError.message(snapshots.isEmpty ? "Copilot 沒有回傳額度資料" : "這個 Copilot 方案沒有額度上限")
        }
        return LimitsResult(plan: plan, windows: windows)
    }

    static func parseResetDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = DateParsing.iso(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
