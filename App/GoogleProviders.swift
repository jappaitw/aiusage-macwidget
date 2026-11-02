import Foundation

/// Gemini CLI 和 Antigravity 共用：Google Code Assist API + OAuth refresh
///
/// Google 的 access token 只有 1 小時。過期時我們會用 refresh token 換一個新的 access token，
/// 但「只放在記憶體」，不寫回 CLI 的檔案（Google 不會輪替 refresh token，所以不會影響 CLI 的登入）。
enum GoogleCodeAssist {
    static func call(base: String, method: String, body: [String: Any], token: String,
                     userAgent: String? = nil) async throws -> [String: Any] {
        var headers = ["Authorization": "Bearer \(token)"]
        if let userAgent { headers["User-Agent"] = userAgent }
        return try await HTTP.json(URL(string: "\(base):\(method)")!, method: "POST", headers: headers, jsonBody: body)
    }

    static func projectID(_ load: [String: Any]) -> String? {
        if let id = load["cloudaicompanionProject"] as? String, !id.isEmpty { return id }
        if let obj = load["cloudaicompanionProject"] as? [String: Any], let id = obj["id"] as? String { return id }
        return nil
    }

    /// paidTier 優先，否則 currentTier 的名稱
    static func plan(_ load: [String: Any]) -> String? {
        for key in ["paidTier", "currentTier"] {
            if let name = (load[key] as? [String: Any])?["name"] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    static func usedPercent(remainingFraction value: Any?) -> Double? {
        guard let fraction = JSONValue.number(value) else { return nil }
        return min(max(100 - fraction * 100, 0), 100)
    }

    // MARK: OAuth

    private static let memo = TokenMemo()

    /// 用 refresh token 換 access token（逐一嘗試 clients），結果暫存在記憶體直到過期
    static func refreshedToken(cacheKey: String, refreshToken: String,
                               clients: () -> [(id: String, secret: String)]) async throws -> String {
        if let cached = memo.get(cacheKey) { return cached }
        let candidates = clients()
        guard !candidates.isEmpty else { throw UsageError.message("登入已過期，而且找不到 CLI 的 OAuth client；開一下 CLI 就會更新") }
        var lastError: Error = UsageError.badResponse
        for client in candidates {
            do {
                let result = try await HTTP.json(URL(string: "https://oauth2.googleapis.com/token")!, form: [
                    "grant_type": "refresh_token", "refresh_token": refreshToken,
                    "client_id": client.id, "client_secret": client.secret,
                ])
                guard let token = result["access_token"] as? String else { throw UsageError.badResponse }
                let lifetime = JSONValue.number(result["expires_in"]) ?? 3600
                memo.set(cacheKey, token: token, expires: Date().addingTimeInterval(lifetime - 120))
                return token
            } catch {
                lastError = error
            }
        }
        if case UsageError.http(let code) = lastError, code == 400 || code == 401 {
            throw UsageError.message("Google 拒絕了 refresh token，重新登入 CLI 一次")
        }
        throw lastError
    }

    /// 從檔案內容找 OAuth client id / secret
    static func findClients(in data: Data, idPattern: String, secretPattern: String) -> [(id: String, secret: String)] {
        let text = String(decoding: data, as: UTF8.self)
        func matches(_ pattern: String, group: Int) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: group), in: text).map { String(text[$0]) }
            }
        }
        let ids = Array(NSOrderedSet(array: matches(idPattern, group: 1)).array as? [String] ?? [])
        let secrets = Array(NSOrderedSet(array: matches(secretPattern, group: 1)).array as? [String] ?? [])
        var pairs: [(id: String, secret: String)] = []
        for id in ids.reversed() {
            for secret in secrets { pairs.append((id: id, secret: secret)) }
        }
        return pairs
    }
}

final class TokenMemo {
    private var tokens: [String: (token: String, expires: Date)] = [:]
    private let lock = NSLock()

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = tokens[key], hit.expires > Date() else { return nil }
        return hit.token
    }

    func set(_ key: String, token: String, expires: Date) {
        lock.lock(); defer { lock.unlock() }
        tokens[key] = (token, expires)
    }
}

// MARK: - Gemini CLI

/// Gemini CLI：讀 ~/.gemini/oauth_creds.json，查 Code Assist 的每模型額度。
/// 註：2026-06 起個人／Google AI Pro／Ultra 帳號改用 Antigravity，Gemini CLI 的額度只剩 Code Assist 方案。
struct GeminiProvider: UsageProvider {
    let id = "gemini"
    let name = "Gemini CLI"

    private var dir: URL {
        let base = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"].map { URL(fileURLWithPath: $0) } ?? Shell.home
        return base.appendingPathComponent(".gemini")
    }
    private var credsFile: URL { dir.appendingPathComponent("oauth_creds.json") }

    func isDetected() -> Bool { Files.exists(credsFile.path) }

    func fetchLimits() async throws -> LimitsResult {
        let settings = Files.json(dir.appendingPathComponent("settings.json"))
        let selected = ((settings?["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
            ?? settings?["selectedAuthType"] as? String
        if let selected, selected != "oauth-personal" {
            throw UsageError.message("Gemini CLI 目前用 \(selected) 登入，沒有額度可查")
        }
        guard let creds = Files.json(credsFile) else { throw UsageError.message("Gemini CLI 尚未登入") }
        let token = try await accessToken(creds)

        let base = "https://cloudcode-pa.googleapis.com/v1internal"
        do {
            let metadata = ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
            let load = try await GoogleCodeAssist.call(base: base, method: "loadCodeAssist",
                                                       body: ["cloudaicompanionProject": NSNull(), "metadata": metadata],
                                                       token: token)
            guard let project = GoogleCodeAssist.projectID(load) else {
                throw UsageError.message("這個 Google 帳號沒有 Code Assist 專案（個人帳號請改看 Antigravity）")
            }
            let quota = try await GoogleCodeAssist.call(base: base, method: "retrieveUserQuota",
                                                        body: ["project": project], token: token)
            var byModel: [String: UsageWindow] = [:]
            for bucket in quota["buckets"] as? [[String: Any]] ?? [] {
                guard let model = bucket["modelId"] as? String,
                      let used = GoogleCodeAssist.usedPercent(remainingFraction: bucket["remainingFraction"]) else { continue }
                if let existing = byModel[model], existing.usedPercent >= used { continue }
                byModel[model] = UsageWindow(label: model, usedPercent: used,
                                             resetsAt: DateParsing.iso(bucket["resetTime"] as? String))
            }
            let windows = byModel.values.sorted { $0.usedPercent > $1.usedPercent }
            if windows.isEmpty { throw UsageError.message("Gemini 沒有回傳額度資料") }
            return LimitsResult(plan: GoogleCodeAssist.plan(load), windows: windows)
        } catch UsageError.http(let code) where code == 401 || code == 403 {
            throw UsageError.message("Gemini 拒絕存取（登入過期，或帳號不是 Code Assist 方案）")
        }
    }

    private func accessToken(_ creds: [String: Any]) async throws -> String {
        if let token = creds["access_token"] as? String, !token.isEmpty,
           let expiry = DateParsing.unix(creds["expiry_date"]), expiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refresh = creds["refresh_token"] as? String, !refresh.isEmpty else {
            throw UsageError.message("Gemini CLI 登入過期，跑一次 gemini 就會更新")
        }
        return try await GoogleCodeAssist.refreshedToken(cacheKey: "gemini:\(refresh.suffix(12))", refreshToken: refresh) {
            if let id = creds["client_id"] as? String, let secret = creds["client_secret"] as? String {
                return [(id: id, secret: secret)]
            }
            return Self.clientsFromInstalledCLI()
        }
    }

    /// Gemini CLI 的 OAuth client 寫在它的 JS 原始碼裡
    private static func clientsFromInstalledCLI() -> [(id: String, secret: String)] {
        guard let binary = Files.executable("gemini") else { return [] }
        let resolved = binary.resolvingSymlinksInPath()
        var files: [URL] = []
        let fm = FileManager.default
        if resolved.deletingLastPathComponent().lastPathComponent == "bundle",
           let items = try? fm.contentsOfDirectory(at: resolved.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            files += items.filter { $0.pathExtension == "js" }
        }
        let relative = [
            "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ]
        let roots = [resolved.deletingLastPathComponent(), resolved.deletingLastPathComponent().deletingLastPathComponent(),
                     URL(fileURLWithPath: "/opt/homebrew/lib"), URL(fileURLWithPath: "/usr/local/lib")]
        for root in roots {
            for path in relative {
                for candidate in [root.appendingPathComponent(path), root.appendingPathComponent("lib/" + path)]
                where fm.fileExists(atPath: candidate.path) {
                    files.append(candidate)
                }
            }
        }
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let found = GoogleCodeAssist.findClients(
                in: data,
                idPattern: #"(?:const|var) OAUTH_CLIENT_ID = ['"]([^'"]+)['"];"#,
                secretPattern: #"(?:const|var) OAUTH_CLIENT_SECRET = ['"]([^'"]+)['"];"#)
            if !found.isEmpty { return found }
        }
        return []
    }
}

// MARK: - Antigravity

/// Antigravity：讀 agy（Antigravity CLI）的 Google 登入，查各模型群組的 5 小時／每週額度
struct AntigravityProvider: UsageProvider {
    let id = "antigravity"
    let name = "Antigravity"

    private var tokenFile: URL { Shell.home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token") }

    func isDetected() -> Bool { Files.exists(tokenFile.path) }

    func fetchLimits() async throws -> LimitsResult {
        guard let auth = Files.json(tokenFile) else { throw UsageError.message("Antigravity CLI（agy）尚未登入") }
        let token = try await accessToken(auth)
        let base = "https://daily-cloudcode-pa.googleapis.com/v1internal"
        let userAgent = "antigravity/cli/\(Self.agyVersion) (aidev_client; os_type=linux; arch=amd64)"
        do {
            let load = try await GoogleCodeAssist.call(base: base, method: "loadCodeAssist",
                                                       body: ["metadata": ["ideType": "ANTIGRAVITY"]],
                                                       token: token, userAgent: userAgent)
            guard let project = GoogleCodeAssist.projectID(load) else { throw UsageError.message("Antigravity 沒有回傳專案") }
            let summary = try await GoogleCodeAssist.call(base: base, method: "retrieveUserQuotaSummary",
                                                          body: ["project": project], token: token, userAgent: userAgent)
            var windows: [UsageWindow] = []
            for group in summary["groups"] as? [[String: Any]] ?? [] {
                var scope = (group["displayName"] as? String) ?? "Quota"
                if scope.lowercased().hasSuffix(" models") { scope = String(scope.dropLast(" models".count)) }
                for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                    guard bucket["disabled"] as? Bool != true,
                          let used = GoogleCodeAssist.usedPercent(remainingFraction: bucket["remainingFraction"]) else { continue }
                    let window: String
                    switch bucket["window"] as? String {
                    case "5h": window = "5 小時"
                    case "weekly": window = "每週"
                    case let other: window = other ?? (bucket["bucketId"] as? String) ?? "額度"
                    }
                    windows.append(UsageWindow(label: "\(scope) · \(window)", usedPercent: used,
                                               resetsAt: DateParsing.iso(bucket["resetTime"] as? String)))
                }
            }
            windows.sort { $0.usedPercent > $1.usedPercent }
            if windows.isEmpty { throw UsageError.message("Antigravity 沒有回傳額度資料") }
            return LimitsResult(plan: GoogleCodeAssist.plan(load), windows: windows)
        } catch UsageError.http(let code) where code == 401 || code == 403 {
            throw UsageError.message("Antigravity 登入過期，開一下 agy 就會更新")
        }
    }

    private func accessToken(_ auth: [String: Any]) async throws -> String {
        let payload = auth["token"] as? [String: Any] ?? auth
        if let token = payload["access_token"] as? String, !token.isEmpty,
           let expiry = DateParsing.iso(payload["expiry"] as? String), expiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refresh = (payload["refresh_token"] as? String) ?? (auth["refresh_token"] as? String), !refresh.isEmpty else {
            throw UsageError.message("Antigravity 登入過期，開一下 agy 就會更新")
        }
        return try await GoogleCodeAssist.refreshedToken(cacheKey: "agy:\(refresh.suffix(12))", refreshToken: refresh) {
            Self.clientsFromBinary()
        }
    }

    /// agy 的 OAuth client 編譯在執行檔裡
    private static func clientsFromBinary() -> [(id: String, secret: String)] {
        guard let binary = Files.executable("agy"),
              let data = try? Data(contentsOf: binary.resolvingSymlinksInPath(), options: .mappedIfSafe) else { return [] }
        return GoogleCodeAssist.findClients(
            in: data,
            idPattern: #"(\d+-[a-z0-9]+\.apps\.googleusercontent\.com)"#,
            secretPattern: #"(GOCSPX-[A-Za-z0-9_-]{28})"#)
    }

    private static let agyVersion: String = {
        guard let binary = Files.executable("agy"),
              let out = Shell.run(binary.path, ["--version"], timeout: 10) else { return "1.4.0" }
        let text = String(decoding: out.stdout, as: UTF8.self)
        guard let range = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return "1.4.0" }
        return String(text[range])
    }()
}
