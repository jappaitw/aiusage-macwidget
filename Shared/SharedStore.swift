import Foundation

/// host app 寫、widget 讀：放在 App Group container 裡的一個 JSON 檔
enum SharedStore {
    static var groupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    }

    static var fileURL: URL? {
        guard let id = groupIdentifier,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        else { return nil }
        return dir.appendingPathComponent("snapshot.json")
    }

    static func load() -> UsageSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
