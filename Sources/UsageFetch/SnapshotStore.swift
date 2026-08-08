import Foundation
import UsageModels

/// Holds the most recent completed snapshot for the loopback server.
public actor SnapshotStore {
    private var encoded: Data

    public init(initial: UsageSnapshot) {
        encoded = (try? UsageSnapshot.encoder().encode(initial)) ?? Data()
    }

    public func update(_ new: UsageSnapshot) {
        encoded = (try? UsageSnapshot.encoder().encode(new)) ?? encoded
    }

    public func body() -> Data { encoded }
}
