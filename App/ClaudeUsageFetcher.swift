import Foundation
import Security

/// Claude 訂閱額度：用 Claude Code 已經登入的 OAuth token 打 /api/oauth/usage
/// （Claude Code 的 /usage 用的同一支 API；非公開、可能改版）
///
/// 刻意「不」幫忙 refresh token：Anthropic 會輪替 refresh token，
/// 這裡 refresh 會讓 Claude Code 手上那份失效、被登出。token 過期就等 Claude Code 下次使用時自己更新。
enum ClaudeUsageFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Anthropic edge 會擋非 claude-code 的 User-Agent（403）
    static let userAgent = "claude-code/2.1.71"
    static let keychainService = "Claude Code-credentials"

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        var plan: String?
    }

    static func fetch() async throws -> LimitsResult {
        let credentials = try loadCredentials()
        if let expiresAt = credentials.expiresAt, expiresAt < Date() {
            throw UsageError.claudeTokenExpired
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw UsageError.claudeTokenExpired
        case 403: throw UsageError.claudeForbidden
        case 429: throw UsageError.rateLimited
        case let code: throw UsageError.http(code)
        }
        return LimitsResult(plan: credentials.plan, windows: try parse(data))
    }

    // MARK: - 解析回應

    static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }
        var ranked: [(rank: Int, window: UsageWindow)] = []

        // 新格式：limits 陣列
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let percent = JSONValue.number(entry["percent"]) else { continue }
                let kind = entry["kind"] as? String ?? "limit"
                let reset = DateParsing.iso(entry["resets_at"] as? String)
                switch kind {
                case "session":
                    ranked.append((0, UsageWindow(label: "5 小時", usedPercent: percent, resetsAt: reset)))
                case "weekly_all":
                    ranked.append((1, UsageWindow(label: "每週", usedPercent: percent, resetsAt: reset)))
                case "weekly_scoped":
                    let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                    let name = (model?["display_name"] as? String) ?? (model?["id"] as? String) ?? "模型"
                    ranked.append((2, UsageWindow(label: "每週 · \(name)", usedPercent: percent, resetsAt: reset)))
                default:
                    ranked.append((3, UsageWindow(label: kind, usedPercent: percent, resetsAt: reset)))
                }
            }
        }

        // 舊格式：five_hour / seven_day / seven_day_opus / seven_day_sonnet
        if ranked.isEmpty {
            let flat: [(key: String, label: String)] = [
                ("five_hour", "5 小時"), ("seven_day", "每週"),
                ("seven_day_opus", "每週 · Opus"), ("seven_day_sonnet", "每週 · Sonnet"),
            ]
            for (index, item) in flat.enumerated() {
                guard let window = root[item.key] as? [String: Any],
                      let percent = JSONValue.number(window["utilization"]) else { continue }
                ranked.append((index, UsageWindow(label: item.label, usedPercent: percent,
                                                  resetsAt: DateParsing.iso(window["resets_at"] as? String))))
            }
        }

        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let utilization = JSONValue.number(extra["utilization"]) {
            ranked.append((9, UsageWindow(label: "額外用量", usedPercent: utilization, resetsAt: nil)))
        }

        if ranked.isEmpty && root["limits"] == nil && root["five_hour"] == nil {
            throw UsageError.badResponse
        }
        return ranked.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { $0.element.window }
    }

    // MARK: - 讀 token

    static func loadCredentials() throws -> Credentials {
        let sources: [() -> Data?] = [readViaSecurityCLI, readViaKeychainAPI, readCredentialsFile]
        for source in sources {
            if let data = source(), let credentials = parseCredentials(data) {
                return credentials
            }
        }
        throw UsageError.claudeNotSignedIn
    }

    /// 優先用 /usr/bin/security：Claude Code 自己就是用它寫入 keychain 的，
    /// 通常已在該項目的存取清單裡，重新 build app 也不會一直跳授權視窗
    private static func readViaSecurityCLI() -> Data? {
        guard let out = Shell.run("/usr/bin/security",
                                  ["find-generic-password", "-s", keychainService, "-w"], timeout: 10),
              out.status == 0 else { return nil }
        let text = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Data(text.utf8)
    }

    /// 備援：直接用 Keychain API（第一次會跳「允許存取」，選「永遠允許」）
    private static func readViaKeychainAPI() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// 再備援：舊版 / 非 macOS 的 Claude Code 會寫在檔案
    private static func readCredentialsFile() -> Data? {
        try? Data(contentsOf: Shell.home.appendingPathComponent(".claude/.credentials.json"))
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let plan = (oauth["rateLimitTier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (oauth["subscriptionType"] as? String)
        return Credentials(accessToken: token, expiresAt: DateParsing.unix(oauth["expiresAt"]), plan: plan)
    }
}
