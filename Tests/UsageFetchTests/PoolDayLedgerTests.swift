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
    // A first reading within 15 minutes of midnight counts as the whole day.
    #expect(day.since == local(0, 0))
    #expect(day.sinceLocal == "00:00")
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

@Test func aReadingInTheHalfHourBeforeMidnightIsTheNextDaysBaseline() throws {
    let ledger = run([
        (local(0, 5), snapshot(member("a", 0.20))),
        (local(23, 55), snapshot(member("a", 0.60))),
        (local(8, 0, day: 6), snapshot(member("a", 0.70))),
    ])
    let day = try #require(ledger.pools["cc3"])
    #expect(day.day == "2026-11-06")
    #expect(near(day.accountsBurned, 0.10))
    #expect(day.logins["cc3/a"]?.baselineAt == local(23, 55))
    #expect(day.sinceLocal == "00:00")
    #expect(day.coversDay)
}

@Test func anOlderLastReadingIsNotCarriedIntoTheNextDay() throws {
    let ledger = run([
        (local(22, 0), snapshot(member("a", 0.60))),
        (local(8, 0, day: 6), snapshot(member("a", 0.70))),
        (local(9, 0, day: 6), snapshot(member("a", 0.75))),
    ])
    let day = try #require(ledger.pools["cc3"])
    #expect(near(day.accountsBurned, 0.05))
    #expect(day.sinceLocal == "08:00")
    #expect(!day.coversDay)
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

// Real line shapes from the devbox proxy-steer log. Midnight in Singapore is 16:00Z.
private let steerLog = """
2026-11-04T08:00:00Z c@x.com weight 30: weekly 60% free, reset in 50.0h, 5h 10% used, burn x0.20
2026-11-04T15:50:00Z c@x.com keep 1: 5h 100% used
2026-11-04T15:58:00Z a@x.com weight 20: weekly 10% free, reset in 3.5h, 5h 40% used, burn x0.47
2026-11-04T15:58:00Z b@x.com keep 1: weekly 100% used
2026-11-04T15:58:00Z d@x.com keep 4: no fresh reading (error)
2026-11-04T16:03:00Z a@x.com weight 20: weekly 8% free, reset in 3.4h, 5h 45% used
2026-11-05T01:00:00Z a@x.com keep 1: weekly 100% used
2026-11-05T01:30:00Z a@x.com weight 40: weekly 97% free, reset in 167.9h, 5h 3% used
2026-11-05T03:00:00Z c@x.com weight 25: weekly 50% free, reset in 31.0h, 5h 20% used
2026-11-05T03:00:00Z e@x.com not set: The request timed out.
"""

@Test func theProxySteerLogYieldsOnlyWeeklyReadings() {
    let readings = LoggedReading.parseProxySteerLog(steerLog)
    #expect(readings.map(\.email) == ["c@x.com", "a@x.com", "b@x.com", "a@x.com", "a@x.com", "a@x.com", "c@x.com"])
    #expect(near(readings[1].week.usedFraction, 0.90))
    #expect(readings[1].week.resetsAt == ISO8601DateFormatter().date(from: "2026-11-04T19:28:00Z"))
    #expect(near(readings[2].week.usedFraction, 1.0))
    #expect(readings[2].week.resetsAt == nil)
}

@Test func aBackfillStartsEachLoginAtItsReadingNearestMidnightAndReplaysTheDay() throws {
    let readings = LoggedReading.parseProxySteerLog(steerLog)
    // The laptop daemon started at 16:03 local, so its own day began late.
    let late = run([(local(16, 3), snapshot(member("a@x.com", 0.03), member("b@x.com", 1.0), member("c@x.com", 0.50, resetsAt: local(18, 0, day: 6))))])
    #expect(!late.coversToday("cc3", at: local(16, 3), calendar: calendar))

    let ledger = late
        .backfilled("cc3", from: readings, at: local(16, 4), calendar: calendar)
        .updated(with: snapshot(member("a@x.com", 0.05), member("b@x.com", 1.0), member("c@x.com", 0.52, resetsAt: local(18, 0, day: 6))),
                 at: local(16, 4), calendar: calendar)
    let day = try #require(ledger.pools["cc3"])
    // a: 0.90 at 23:58, 0.92, 1.00, reset, 0.03 at 09:30, then 0.05 live: 0.10 + 0.05.
    #expect(near(day.logins["cc3/a@x.com"]?.burned, 0.15))
    // b: 100% at 23:58 and still 100%: nothing.
    #expect(near(day.logins["cc3/b@x.com"]?.burned, 0))
    // c: its last weekly line before midnight is 16:00 local, 0.40; then 0.50 and 0.52 live.
    #expect(near(day.logins["cc3/c@x.com"]?.burned, 0.12))
    #expect(near(day.accountsBurned, 0.27))
    #expect(day.coversDay)
    #expect(day.sinceLocal == "00:00")
    #expect(day.memberCount == 3)
    #expect(ledger.coversToday("cc3", at: local(16, 4), calendar: calendar))
}

@Test func aLoggedReadingMoreThanTwelveHoursBeforeMidnightIsNoBaseline() throws {
    let log = """
    2026-11-04T03:59:00Z a@x.com weight 30: weekly 60% free, reset in 50.0h, 5h 10% used
    2026-11-05T02:00:00Z a@x.com weight 30: weekly 50% free, reset in 25.0h, 5h 10% used
    """
    let ledger = PoolDayLedger().backfilled(
        "cc3", from: LoggedReading.parseProxySteerLog(log), at: local(11, 0), calendar: calendar)
    let day = try #require(ledger.pools["cc3"])
    #expect(near(day.accountsBurned, 0))
    #expect(day.sinceLocal == "10:00")
    #expect(!day.coversDay)
}

private struct FixedPool: UsageProviderClient {
    let week: Double
    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        ProviderReading(windows: [], members: [member("a@x.com", week)])
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
    #expect(near(day.logins["cc3/a@x.com"]?.last, 0.4))
    #expect(near(day.accountsBurned, 0))
}

private actor SeedCalls {
    private(set) var pools: [String] = []
    func record(_ pool: String) { pools.append(pool) }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@Test func theCoordinatorSeedsALateDayOnceAndThenRetriesOnlyAfterHalfAnHour() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("pool-day-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let config = Config(accounts: [AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3", cliProxyURL: "http://127.0.0.1:1")])
    let calls = SeedCalls()
    // The seed log has no reading near midnight, so the day stays uncovered.
    let log = "2026-11-05T02:00:00Z a@x.com weight 30: weekly 60% free, reset in 25.0h, 5h 10% used\n"
    let clock = Clock(Date())
    let coordinator = RefreshCoordinator(
        store: SnapshotStore(initial: .empty), collector: UsageCollector(poolClient: FixedPool(week: 0.45)),
        config: config, now: { clock.now }, poolDayPath: path,
        poolDaySeed: { pool in await calls.record(pool); return log })
    for minutes in [0.0, 5, 10, 31] {
        clock.now = Date().addingTimeInterval(minutes * 60)
        await coordinator.refresh(force: true)
        await coordinator.waitForRefresh()
    }
    #expect(await calls.pools == ["cc3", "cc3"])
}
