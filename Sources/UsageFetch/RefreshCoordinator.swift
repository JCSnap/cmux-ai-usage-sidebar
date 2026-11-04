import Foundation
import UsageModels

public struct DaemonResponse: Sendable {
    public let body: Data
    public let isRefreshing: Bool
}

/// Coordinates background and on-demand provider fetches.
///
/// Refreshes are coalesced so concurrent requests share a single fetch task,
/// and debounced so rapid manual refreshes do not flood provider APIs.
public actor RefreshCoordinator {
    private let store: SnapshotStore
    private let collector: UsageCollector
    private var config: Config
    private var inFlight: Task<Void, Never>?
    private var lastRefresh: Date = .distantPast
    private var refreshAgain = false
    private let now: @Sendable () -> Date
    private let saveConfig: @Sendable (Config) throws -> Void

    public init(
        store: SnapshotStore, collector: UsageCollector, config: Config,
        now: @escaping @Sendable () -> Date = { Date() },
        saveConfig: @escaping @Sendable (Config) throws -> Void = { try $0.save() }
    ) {
        self.store = store
        self.collector = collector
        self.config = config
        self.now = now
        self.saveConfig = saveConfig
    }

    /// Start one collection. HTTP callers receive the current snapshot immediately.
    public func refresh(force: Bool = false) {
        guard inFlight == nil else { return }
        guard force || now().timeIntervalSince(lastRefresh) >= 60 else { return }
        let collectingConfig = config
        inFlight = Task {
            let prev = await store.snapshot()
            let newSnapshot = await collector.collect(collectingConfig, previous: prev)
            // A visibility change made during collection must survive completion.
            await store.update(UsageCollector.applyingVisibility(config, to: newSnapshot))
            lastRefresh = now()
            inFlight = nil
            if refreshAgain {
                refreshAgain = false
                refresh(force: true)
            }
        }
    }

    /// Background scheduling waits here, outside the HTTP request path.
    public func waitForRefresh() async {
        while let inFlight { await inFlight.value }
    }

    /// Hides or shows one account and saves the choice to the config file, so
    /// it survives a restart. Hiding drops the row at once; showing reads the
    /// accounts again, because a hidden account has no numbers to put back.
    private func setHidden(_ id: String, _ hidden: Bool) async {
        var changed = config
        guard changed.setHidden(id, hidden), changed.isHidden(id) != config.isHidden(id) else {
            return
        }
        do {
            try saveConfig(changed)
        } catch {
            FileHandle.standardError.write(Data("aiusaged: could not save \(Config.path): \(error)\n".utf8))
            return
        }
        config = changed
        if hidden {
            await store.update(UsageCollector.applyingVisibility(config, to: await store.snapshot()))
            return
        }
        // The current collection may have skipped this newly shown account.
        if inFlight != nil { refreshAgain = true }
        refresh(force: true)
    }

    public func handle(_ request: DaemonRequest) async -> DaemonResponse {
        switch request {
        case .snapshot: break
        case .refresh: refresh()
        case let .setHidden(id, hidden): await setHidden(id, hidden)
        }
        let pending = inFlight != nil
        return DaemonResponse(body: await store.body(), isRefreshing: pending)
    }
}

