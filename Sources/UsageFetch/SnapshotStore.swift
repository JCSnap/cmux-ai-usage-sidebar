import Foundation
import UsageModels

/// Holds the most recent completed snapshot for the loopback server.
public actor SnapshotStore {
    private var current: UsageSnapshot
    private var encoded: Data

    public init(initial: UsageSnapshot) {
        self.current = initial
        self.encoded = (try? UsageSnapshot.encoder().encode(initial)) ?? Data()
    }

    public func update(_ new: UsageSnapshot) {
        self.current = new
        self.encoded = (try? UsageSnapshot.encoder().encode(new)) ?? encoded
    }

    public func body() -> Data { encoded }

    public func snapshot() -> UsageSnapshot { current }
}
