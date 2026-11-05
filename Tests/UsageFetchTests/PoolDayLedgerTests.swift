import Foundation
import Testing
import UsageModels
@testable import UsageFetch

/// Singapore has no daylight saving, so every local time below is fixed.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    return calendar
}()

/// 2026-11-05 at `hour:minute` in Singapore (UTC+8).
private func local(_ hour: Int, _ minute: Int = 0, day: Int = 5) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private let weekEnd = local(12, 0, day: 8)

private func member(
    _ id: String, _ week: Double?, resetsAt: Date? = weekEnd, state: UsageAccountState = .ok
) -> UsageAccount {
    let windows = week.map { [
        UsageWindow(label: "5h", usedFraction: 0.5),
        UsageWindow(label: "7d", usedFraction: $0, resetsAt: resetsAt),
    ] } ?? []
    return UsageAccount(id: "cc3/\(id)", provider: .claude, displayName: id, state: state, windows: windows)
}

private func snapshot(_ members: UsageAccount..., poolState: UsageAccountState = .ok) -> UsageSnapshot {
    UsageSnapshot(generatedAt: .distantPast, accounts: [
        UsageAccount(id: "cc1", provider: .claude, displayName: "cc1", state: .ok,
                     windows: [UsageWindow(label: "7d", usedFraction: 0.3)]),
        UsageAccount(id: "cc3", provider: .claude, displayName: "pool", state: poolState,
                     members: members),
    ])
}

private func run(_ cycles: [(Date, UsageSnapshot)], from start: PoolDayLedger = PoolDayLedger()) -> PoolDayLedger {
    cycles.reduce(start) { $0.updated(with: $1.1, at: $1.0, calendar: calendar) }
}

private func near(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
}

@Test func sumsEachLoginsRiseAsAccountsAndSkipsOrdinaryAccounts() throws {
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.20), member("b", 0.50))),
        (local(9, 0), snapshot(member("a", 0.35), member("b", 0.50))),
        (local(14, 0), snapshot(member("a", 0.60), member("b", 0.75))),
    ])
    #expect(Array(ledger.pools.keys) == ["cc3"])
    let day = try #require(ledger.pools["cc3"])
    #expect(day.day == "2026-11-05")
    #expect(near(day.accountsBurned, 0.65))
    #expect(day.memberCount == 2)
    #expect(near(day.breakEvenAccountsPerDay, 2.0 / 7.0))
    #expect(day.since == local(0, 5))
    #expect(day.sinceLocal == "00:05")
    #expect(day.coversDay)
    #expect(!day.partial)
    #expect(day.updatedAt == local(14, 0))
}

@Test func aWeeklyResetAddsTheRiseBeforeItAndCountsTheNewWindowFromZero() throws {
    let later = weekEnd.addingTimeInterval(7 * 86_400)
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.90, resetsAt: local(11, 0)))),
        (local(10, 55), snapshot(member("a", 0.95, resetsAt: local(11, 0)))),
        (local(11, 5), snapshot(member("a", 0.02, resetsAt: later))),
        (local(15, 0), snapshot(member("a", 0.10, resetsAt: later))),
    ])
    let login = try #require(ledger.pools["cc3"]?.logins["cc3/a"])
    #expect(near(login.earlierWindows, 0.05))
    #expect(login.baseline == 0)
    // 0.95 - 0.90 before the reset, then 0.10 in the new window.
    #expect(near(ledger.pools["cc3"]?.accountsBurned, 0.15))
}

@Test func aResetWithoutAResetTimeIsCountedOnce() {
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.80))),
        (local(8, 0), snapshot(member("a", 0.00, resetsAt: nil))),
        (local(9, 0), snapshot(member("a", 0.04, resetsAt: weekEnd.addingTimeInterval(7 * 86_400)))),
    ])
    #expect(near(ledger.pools["cc3"]?.accountsBurned, 0.04))
}

@Test func aVendorRoundingTheResetTimeIsNotAReset() {
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.40, resetsAt: weekEnd))),
        (local(9, 0), snapshot(member("a", 0.45, resetsAt: weekEnd.addingTimeInterval(1)))),
    ])
    #expect(near(ledger.pools["cc3"]?.accountsBurned, 0.05))
}

@Test func aLoginWithoutAFreshReadingKeepsItsLastValueAndMarksThePartial() throws {
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.20), member("b", 0.50))),
        (local(9, 0), snapshot(member("a", 0.30), member("b", 0.70))),
        (local(10, 0), snapshot(member("a", 0.40), member("b", nil, state: .stale))),
    ])
    let day = try #require(ledger.pools["cc3"])
    #expect(near(day.accountsBurned, 0.40))
    #expect(day.partial)
    #expect(day.missing == ["cc3/b"])
    #expect(near(day.logins["cc3/b"]?.last, 0.70))

    // The next fresh reading clears the mark and counts from the same baseline.
    let healed = run([(local(11, 0), snapshot(member("a", 0.40), member("b", 0.80)))], from: ledger)
    #expect(healed.pools["cc3"]?.partial == false)
    #expect(near(healed.pools["cc3"]?.accountsBurned, 0.50))
}

@Test func aFailedPoolReadCountsNoMemberAsFresh() {
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.20))),
        (local(9, 0), snapshot(member("a", 0.90), poolState: .stale)),
    ])
    #expect(near(ledger.pools["cc3"]?.accountsBurned, 0))
    #expect(ledger.pools["cc3"]?.missing == ["cc3/a"])
}

@Test func aNewLocalDayStartsAFreshEntryFromItsFirstReading() throws {
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.20))),
        (local(23, 55), snapshot(member("a", 0.60))),
        (local(0, 3, day: 6), snapshot(member("a", 0.62))),
        (local(8, 0, day: 6), snapshot(member("a", 0.70))),
    ])
    let day = try #require(ledger.pools["cc3"])
    #expect(day.day == "2026-11-06")
    #expect(near(day.accountsBurned, 0.08))
    #expect(day.sinceLocal == "00:03")
    #expect(day.coversDay)
}

@Test func aBaselineTakenLateInTheDaySaysWhenCountingStarted() throws {
    let ledger = run([
        (local(9, 12), snapshot(member("a", 0.20))),
        (local(10, 0), snapshot(member("a", 0.25))),
    ])
    let day = try #require(ledger.pools["cc3"])
    #expect(day.sinceLocal == "09:12")
    #expect(!day.coversDay)
}

@Test func theLedgerSurvivesASaveAndLoad() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("pool-day-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.20))),
        (local(9, 0), snapshot(member("a", 0.30))),
    ])
    ledger.save(to: path)
    #expect(PoolDayLedger.load(from: path) == ledger)
}

private struct FixedPool: UsageProviderClient {
    let week: Double
    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        ProviderReading(windows: [], members: [member("a", week)])
    }
}

@Test func theCoordinatorWritesTheLedgerAfterEachCollection() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("pool-day-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let config = Config(accounts: [AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3", cliProxyURL: "http://127.0.0.1:1")])
    let coordinator = RefreshCoordinator(
        store: SnapshotStore(initial: .empty), collector: UsageCollector(poolClient: FixedPool(week: 0.4)),
        config: config, poolDayPath: path)
    await coordinator.refresh(force: true)
    await coordinator.waitForRefresh()
    let day = try #require(PoolDayLedger.load(from: path)?.pools["cc3"])
    #expect(day.memberCount == 1)
    #expect(near(day.logins["cc3/a"]?.last, 0.4))
    #expect(near(day.accountsBurned, 0))
}
