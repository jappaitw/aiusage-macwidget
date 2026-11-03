import Foundation

/// host app 寫、widget 讀的 snapshot.json。寫到兩個地方：
/// 1. App Group container——正式簽章（有 Team ID）的 build 用這條
/// 2. ~/Library/Application Support/AIUsage/——ad-hoc 簽章的 App Group 授權無效、
///    sandbox 會擋 widget 讀 group container，所以 widget 另外帶一個
///    temporary-exception 唯讀權限來讀這個資料夾（見 project.yml）
enum SharedStore {
    static var groupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    }

    static var groupFileURL: URL? {
        guard let id = groupIdentifier,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        else { return nil }
        return dir.appendingPathComponent("snapshot.json")
    }

    /// sandbox 裡 homeDirectoryForCurrentUser 是 container 的家目錄，要用 getpwuid 拿真的
    private static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var fallbackFileURL: URL {
        realHome.appendingPathComponent("Library/Application Support/AIUsage/snapshot.json")
    }

    private static var allURLs: [URL] {
        var urls: [URL] = []
        if let group = groupFileURL { urls.append(group) }
        urls.append(fallbackFileURL)
        return urls
    }

    /// 兩個位置都讀，取比較新的那份
    static func load() -> UsageSnapshot? {
        allURLs
            .compactMap { url -> UsageSnapshot? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
            }
            .max { $0.generatedAt < $1.generatedAt }
    }

    /// 兩個位置都寫；至少一個成功就算成功
    static func save(_ snapshot: UsageSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        var firstError: Error?
        var wroteAny = false
        for url in allURLs {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                wroteAny = true
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !wroteAny { throw firstError ?? CocoaError(.fileWriteUnknown) }
    }
}
