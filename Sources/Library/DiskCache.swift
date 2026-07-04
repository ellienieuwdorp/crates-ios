import Foundation

/// Tiny JSON-on-disk cache under Application Support. Cold start reads straight from here so the
/// first frame after launch is populated, not empty (Philosophy #3: "the cache is the app").
actor DiskCache {
    static let shared = DiskCache()
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("CratesCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fileURL(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent("\(safe).json")
    }

    func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: fileURL(key), options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
