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
    /// Where the daily pool ledger lives. Nil keeps no ledger.
    private let poolDayPath: String?
    private var poolDay: PoolDayLedger
    /// Reads the seed log for one pool id, or nil when none is set or it failed.
    private let poolDaySeed: (@Sendable (String) async -> String?)?
    private var lastSeedAttempt: [String: Date] = [:]
    /// Writes one line to the daemon log.
    private let log: @Sendable (String) -> Void
    /// Whether the last ledger write failed. A failure is logged once, and so
    /// is the next write that works, so a stale ledger shows in the log.
    private var poolDayWriteFailing = false
    /// A failed or partial seed is tried again after this long.
    static let seedRetry: TimeInterval = 30 * 60

    public init(
        store: SnapshotStore, collector: UsageCollector, config: Config,
        now: @escaping @Sendable () -> Date = { Date() },
        saveConfig: @escaping @Sendable (Config) throws -> Void = { try $0.save() },
        poolDayPath: String? = nil,
        poolDaySeed: (@Sendable (String) async -> String?)? = nil,
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data("aiusaged: \($0)\n".utf8)) }
    ) {
        self.store = store
        self.collector = collector
        self.config = config
        self.now = now
        self.saveConfig = saveConfig
        self.poolDayPath = poolDayPath
        self.poolDay = poolDayPath.flatMap { PoolDayLedger.load(from: $0) } ?? PoolDayLedger()
        self.poolDaySeed = poolDaySeed
        self.log = log
    }

    /// Adds one collection to the daily pool ledger. It reads no vendor API.
    ///
    /// When today's entry does not start at midnight, it first rebuilds the day
    /// from the seed log, at most once per `seedRetry`.
    private func recordPoolDay(_ snapshot: UsageSnapshot) async {
        guard let poolDayPath else { return }
        if let poolDaySeed {
            for pool in snapshot.accounts where pool.isPool {
                let at = now()
                guard !poolDay.coversToday(pool.id, at: at),
                      lastSeedAttempt[pool.id].map({ at.timeIntervalSince($0) >= Self.seedRetry }) ?? true
                else { continue }
                lastSeedAttempt[pool.id] = at
                guard let log = await poolDaySeed(pool.id) else { continue }
                poolDay = poolDay.backfilled(
                    pool.id, from: LoggedReading.parseProxySteerLog(log), at: now())
            }
        }
        poolDay = poolDay.updated(with: snapshot, at: now())
        do {
            try poolDay.save(to: poolDayPath)
            if poolDayWriteFailing { log("wrote \(poolDayPath) again") }
            poolDayWriteFailing = false
        } catch {
            if !poolDayWriteFailing { log("could not write \(poolDayPath): \(error)") }
            poolDayWriteFailing = true
        }
    }

    /// Start one collection. HTTP callers receive the current snapshot immediately.
    public func refresh(force: Bool = false) {
        guard inFlight == nil else { return }
        guard force || now().timeIntervalSince(lastRefresh) >= 60 else { return }
        let collectingConfig = config
        inFlight = Task {
            let prev = await store.snapshot()
            let newSnapshot = await collector.collect(collectingConfig, previous: prev)
            await recordPoolDay(newSnapshot)
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
            log("could not save \(Config.path): \(error)")
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

