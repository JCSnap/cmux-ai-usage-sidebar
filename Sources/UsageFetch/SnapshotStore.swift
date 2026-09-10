import Foundation
import UsageModels

/// Holds the most recent completed snapshot for the loopback server.
public actor SnapshotStore {
    private var current: UsageSnapshot
    private var encoded: Data
    private let cachePath: String?

    public init(initial: UsageSnapshot, cachePath: String? = nil) {
        self.current = initial
        self.encoded = (try? UsageSnapshot.encoder().encode(initial)) ?? Data()
        self.cachePath = cachePath
    }

    public func update(_ new: UsageSnapshot) {
        self.current = new
        self.encoded = (try? UsageSnapshot.encoder().encode(new)) ?? encoded
        if let cachePath {
            Self.saveCache(new, to: cachePath)
        }
    }

    public func body() -> Data { encoded }

    public func snapshot() -> UsageSnapshot { current }

    /// Reads the last persisted snapshot from disk, if available and valid.
    public static func loadCache(from path: String = Config.cachePath) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let snapshot = try? UsageSnapshot.decoder().decode(UsageSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    /// Persists a snapshot atomically to disk.
    public static func saveCache(_ snapshot: UsageSnapshot, to path: String = Config.cachePath) {
        guard let data = try? UsageSnapshot.encoder().encode(snapshot) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
