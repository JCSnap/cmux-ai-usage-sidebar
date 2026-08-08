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

    public init() {}

    public func collect(_ config: Config) async -> UsageSnapshot {
        let accounts = await withTaskGroup(of: (Int, UsageAccount).self) { group in
            for (index, account) in config.accounts.enumerated() {
                group.addTask { (index, await read(account)) }
            }
            var collected: [(Int, UsageAccount)] = []
            for await result in group { collected.append(result) }
            // Restore configuration order; task completion order is arbitrary.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return UsageSnapshot(generatedAt: Date(), accounts: accounts)
    }

    private func read(_ account: AccountConfig) async -> UsageAccount {
        guard let client = clients[account.provider] else {
            return UsageAccount(
                id: account.id, provider: account.provider,
                displayName: account.displayName, state: .error,
                detail: "no client for \(account.provider.rawValue)")
        }
        do {
            let reading = try await client.fetch(account)
            return UsageAccount(
                id: account.id, provider: account.provider,
                displayName: account.displayName, plan: reading.plan, email: reading.email,
                state: .ok, windows: reading.windows)
        } catch FetchError.noCredential {
            // Not an error worth showing red. The account just needs a login.
            return UsageAccount(
                id: account.id, provider: account.provider,
                displayName: account.displayName, state: .signedOut)
        } catch {
            return UsageAccount(
                id: account.id, provider: account.provider,
                displayName: account.displayName, state: .error,
                detail: error.localizedDescription)
        }
    }
}
