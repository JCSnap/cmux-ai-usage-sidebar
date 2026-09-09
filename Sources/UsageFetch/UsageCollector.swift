import Foundation
import UsageModels

/// Reads every configured account concurrently and folds the results into one
/// snapshot. One account failing never fails the snapshot.
public struct UsageCollector: Sendable {
    private let clients: [UsageProvider: any UsageProviderClient] = [
        .claude: ClaudeClient(),
        .codex: CodexClient(),
        .grok: GrokClient(),
        .antigravity: AntigravityClient(),
    ]

    /// How long numbers from a failed read stay on screen. Past this the row
    /// shows the failure instead, because a bar that never expires reads as
    /// live and is then worse than no bar at all.
    public static let staleLimit: TimeInterval = 30 * 60

    public init() {}

    /// Reads every account. `previous` is the snapshot this one replaces; an
    /// account that fails now keeps its earlier numbers while they are fresh.
    public func collect(
        _ config: Config,
        previous: UsageSnapshot = .empty,
        now: Date = Date()
    ) async -> UsageSnapshot {
        let earlier = Dictionary(previous.accounts.map { ($0.id, $0) }) { first, _ in first }
        let accounts = await withTaskGroup(of: (Int, UsageAccount).self) { group in
            for (index, account) in config.accounts.enumerated() {
                group.addTask { (index, await read(account, earlier: earlier[account.id], now: now)) }
            }
            var collected: [(Int, UsageAccount)] = []
            for await result in group { collected.append(result) }
            // Restore configuration order; task completion order is arbitrary.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return UsageSnapshot(generatedAt: now, accounts: accounts)
    }

    private func read(
        _ account: AccountConfig, earlier: UsageAccount?, now: Date
    ) async -> UsageAccount {
        guard let client = clients[account.provider] else {
            return Self.failed(
                account, earlier: earlier, now: now,
                detail: "no client for \(account.provider.rawValue)")
        }
        do {
            let reading = try await client.fetch(account)
            return UsageAccount(
                id: account.id, provider: account.provider,
                displayName: account.displayName, plan: reading.plan, email: reading.email,
                state: .ok, windows: reading.windows, updatedAt: now)
        } catch FetchError.noCredential {
            // Not an error worth showing red. The account just needs a login.
            return UsageAccount(
                id: account.id, provider: account.provider,
                displayName: account.displayName, state: .signedOut)
        } catch {
            return Self.failed(account, earlier: earlier, now: now, detail: error.localizedDescription)
        }
    }

    /// Builds the row for a read that failed. Recent numbers from the previous
    /// snapshot are carried over as `.stale`, so one rate-limited call does not
    /// blank the panel until the next cycle. `updatedAt` stays at the last good
    /// read, so a run of failures ages out instead of renewing itself.
    static func failed(
        _ account: AccountConfig, earlier: UsageAccount?, now: Date, detail: String
    ) -> UsageAccount {
        if let earlier, !earlier.windows.isEmpty, let read = earlier.updatedAt,
           now.timeIntervalSince(read) < Self.staleLimit {
            return UsageAccount(
                id: account.id, provider: account.provider,
                displayName: account.displayName, plan: earlier.plan, email: earlier.email,
                state: .stale, windows: earlier.windows, detail: detail, updatedAt: read)
        }
        return UsageAccount(
            id: account.id, provider: account.provider,
            displayName: account.displayName, state: .error, detail: detail)
    }
}
