import Foundation
import Testing
import UsageModels
@testable import UsageFetch

private let now = Date(timeIntervalSince1970: 1_794_000_000)
private func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }

private func logins(_ count: Int, used: Double, resetIn h: Double) -> [PoolBudget.Login] {
    Array(repeating: PoolBudget.Login(remaining: 1 - used, resetsAt: hours(h)), count: count)
}

private func near(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
}

/// Case 1: two heavy days. Eight logins reset together in 5 days with 31.25%
/// left each, so 2.5 accounts must last, and be used within, 5 days.
@Test func heavyEarlyUseLeavesHalfAnAccountADay() throws {
    let budget = try #require(PoolBudget.compute(logins(8, used: 0.6875, resetIn: 120), at: now))
    #expect(near(budget.ceilingAccountsPerDay, 0.5))
    #expect(budget.ceilingDeadline == hours(120))
    #expect(near(budget.floorAccounts, 2.5))
    #expect(near(budget.floorAccountsPerDay, 0.5))
    #expect(budget.floorDeadline == hours(120))
}

/// Case 2: three light days. Eight unused logins reset in 4 days, so the pool
/// can, and should, use 2 accounts a day.
@Test func lightEarlyUseAllowsTwoAccountsADay() throws {
    let budget = try #require(PoolBudget.compute(logins(8, used: 0, resetIn: 96), at: now))
    #expect(near(budget.ceilingAccountsPerDay, 2.0))
    #expect(budget.ceilingDeadline == hours(96))
    #expect(near(budget.floorAccounts, 8))
    #expect(near(budget.floorAccountsPerDay, 2.0))
}

/// Case 3: staggered resets. One login resets in 12 hours with 90% left, so 0.9
/// of an account must go in those 12 hours. The other resets in 5 days with
/// half left: by then the pool holds 1.4 now plus the first login's refill.
@Test func anUnderusedLoginResettingSoonSetsTheFloor() throws {
    let budget = try #require(PoolBudget.compute([
        PoolBudget.Login(remaining: 0.9, resetsAt: hours(12)),
        PoolBudget.Login(remaining: 0.5, resetsAt: hours(120)),
    ], at: now))
    #expect(near(budget.floorAccounts, 0.9))
    #expect(near(budget.floorAccountsPerDay, 1.8))
    #expect(budget.floorDeadline == hours(12))
    // (0.9 + 0.5 + 1 refill) / 5 days. At 12 hours it is 1.4 / 0.5 = 2.8, at
    // 7 days (1.4 + 2) / 7 = 0.486.
    #expect(near(budget.ceilingAccountsPerDay, 0.48))
    #expect(budget.ceilingDeadline == hours(120))
}

@Test func aResetTimeInThePastCountsAsAFullAccountOneWeekLater() throws {
    let budget = try #require(PoolBudget.compute([
        PoolBudget.Login(remaining: 0, resetsAt: hours(-2)),
    ], at: now))
    #expect(near(budget.floorAccounts, 1))
    #expect(budget.floorDeadline == hours(166))
}

@Test func aLoginWithoutAResetTimeCountsInTheCeilingOnly() throws {
    let budget = try #require(PoolBudget.compute([PoolBudget.Login(remaining: 0.7, resetsAt: nil)], at: now))
    #expect(budget.floorDeadline == nil)
    #expect(budget.floorAccountsPerDay == 0)
    #expect(near(budget.ceilingAccountsPerDay, 0.1))
    #expect(PoolBudget.compute([], at: now) == nil)
}

@Test func paceIsTheBurnOverTheLastSixHoursPerDay() {
    let samples = [
        BurnSample(at: hours(-8), total: 0),
        BurnSample(at: hours(-6), total: 1.0),
        BurnSample(at: hours(-3), total: 1.2),
        BurnSample(at: hours(0), total: 1.5),
    ]
    // 0.5 accounts in 6 hours is 2 a day. The burn before the window is ignored.
    #expect(near(PoolBudget.pace(samples, at: now), 2.0))
    // Less than one hour of samples gives no pace.
    #expect(PoolBudget.pace([BurnSample(at: hours(-0.5), total: 0), BurnSample(at: now, total: 0.1)], at: now) == nil)
    // With no sample 6 hours old, the pace starts at the oldest.
    #expect(near(PoolBudget.pace(Array(samples.suffix(2)), at: now), 2.4))
}
