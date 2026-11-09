import Foundation
import Testing
import UsageModels
@testable import ProxySteer

private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func member(
    _ email: String, state: UsageAccountState = .ok, used: [Double] = [],
    resetsIn hours: [Double?] = [], detail: String? = nil
) -> UsageAccount {
    let windows = zip(used, hours).enumerated().map { index, pair in
        UsageWindow(
            label: index == 0 ? "5h" : "7d", usedFraction: pair.0,
            resetsAt: pair.1.map { now.addingTimeInterval($0 * 3600) })
    }
    return UsageAccount(
        id: "cc3/\(email)", provider: .claude, displayName: email, email: email,
        state: state, windows: windows, detail: detail)
}

// MARK: - Earliest-deadline-first rule

private func weights(_ decisions: [SteerWeight.Decision]) -> [Int?] {
    decisions.map { decision in
        if case .weight(let weight, _) = decision { return weight }
        return nil
    }
}

/// The pool on 2026-11-09, labelled generically. Two logins reset on Tuesday
/// with 19% left. Six reset on Saturday or Sunday, mostly unused. The weekly
/// rule gave all eight 20 to 36, so traffic was near even. Under EDF the two
/// Tuesday logins take 339 of 402, or 84% of new sessions.
@Test func edfSpendsTheTuesdayLoginsFirst() {
    let pool = [
        member("tue1@x", used: [0.00, 0.81], resetsIn: [5, 30]),
        member("tue2@x", used: [0.10, 0.81], resetsIn: [3, 31]),
        member("sat1@x", used: [0.05, 0.08], resetsIn: [2, 120]),
        member("sat2@x", used: [0.00, 0.08], resetsIn: [5, 123]),
        member("sat3@x", used: [0.06, 0.19], resetsIn: [4, 120]),
        member("sun1@x", used: [0.07, 0.08], resetsIn: [1, 135]),
        member("sun2@x", used: [0.08, 0.20], resetsIn: [2, 141]),
        member("sun3@x", used: [0.00, 0.08], resetsIn: [5, 142]),
    ]
    let decisions = SteerWeight.decide(pool, now: now)
    #expect(weights(decisions) == [190, 149, 13, 13, 12, 9, 7, 9])
    #expect(decisions[1] == .weight(149, reason: "weekly 19% free, reset in 31.0h (earliest 30.0h), 5h 10% used"))
    // The weekly rule on the same pool: near even.
    #expect(weights(pool.map { SteerWeight.decide($0, now: now, basis: .weekly) }) == [32, 27, 36, 37, 32, 31, 20, 32])
}

/// A login that resets in 12 hours with 90% left takes nearly all new sessions.
@Test func edfLoginAboutToResetWithHeadroomTakesTheTop() {
    let pool = [
        member("soon@x", used: [0.0, 0.10], resetsIn: [5, 12]),
        member("sat@x", used: [0.0, 0.08], resetsIn: [5, 120]),
    ]
    #expect(SteerWeight.decide(pool, now: now) == [
        .weight(900, reason: "weekly 90% free, reset in 12.0h (earliest 12.0h), 5h 0% used"),
        .weight(1, reason: "weekly 92% free, reset in 120.0h (earliest 12.0h), 5h 0% used"),
    ])
}

/// A login at its 5-hour limit leaves the top tier, and the next deadline leads.
@Test(arguments: [0.75, 0.90, 1.0])
func edfLoginAtFiveHourLimitLeavesTheTop(fiveUsed: Double) {
    let pool = [
        member("tue@x", used: [fiveUsed, 0.81], resetsIn: [1, 30]),
        member("sat@x", used: [0.0, 0.08], resetsIn: [5, 120]),
    ]
    #expect(SteerWeight.decide(pool, now: now) == [
        .weight(1, reason: "5h \(Int((fiveUsed * 100).rounded()))% used"),
        .weight(920, reason: "weekly 92% free, reset in 120.0h (earliest 120.0h), 5h 0% used"),
    ])
}

@Test(arguments: [
    // The 5-hour factor (0.75 - used) / 0.75 spills new sessions to the next login.
    (0.50, [Int?.some(63), .some(14)]),
    (0.74, [.some(3), .some(14)]),
])
func edfFiveHourFactorSpillsToTheNextDeadline(fiveUsed: Double, expected: [Int?]) {
    let pool = [
        member("tue@x", used: [fiveUsed, 0.81], resetsIn: [1, 30]),
        member("sat@x", used: [0.0, 0.08], resetsIn: [5, 120]),
    ]
    #expect(weights(SteerWeight.decide(pool, now: now)) == expected)
}

@Test func edfGatesAndUnreadableMembersDoNotSetTheEarliestDeadline() {
    let pool = [
        member("full@x", used: [0.0, 0.96], resetsIn: [5, 10]),
        member("cool@x", state: .error, detail: "HTTP 429: rate limited"),
        member("stale@x", state: .stale, detail: "timed out"),
        member("seat@x", used: [0.5], resetsIn: [1]),
        member("sat@x", used: [0.0, 0.08], resetsIn: [5, 120]),
        member("none@x", used: [0.0, 0.0], resetsIn: [5, nil]),
    ]
    #expect(SteerWeight.decide(pool, now: now) == [
        .weight(1, reason: "weekly 96% used"),
        .weight(1, reason: "cooling down"),
        .keep(reason: "no fresh reading (stale)"),
        // A team seat with no weekly window falls back to the tightest rule.
        .weight(125, reason: "50% free, reset in 1.0h"),
        .weight(920, reason: "weekly 92% free, reset in 120.0h (earliest 120.0h), 5h 0% used"),
        // No weekly reset time: a full week away.
        .weight(364, reason: "weekly 100% free, reset in 168.0h (earliest 120.0h), 5h 0% used"),
    ])
}

@Test func edfPlanComparesOnlyLoginsTheProxyHolds() throws {
    let snap = snapshot(age: 60, members: [
        member("a@x", used: [0.0, 0.10], resetsIn: [5, 120]),
        // c@x has no claude login, so its early reset does not count.
        member("c@x", used: [0.0, 0.10], resetsIn: [5, 12]),
    ])
    let rows = try ProxySteer.plan(snapshot: snap, poolID: "cc3", entries: entries, now: now)
    #expect(rows.map(\.newWeight) == [900, nil])
    #expect(rows.map(\.reason) == ["weekly 90% free, reset in 120.0h (earliest 120.0h), 5h 0% used", "no proxy login"])
}

// MARK: - Weekly weight rule

/// `used` and `hours` list the 5-hour window first, then the weekly window.
@Test(arguments: [
    // Free weekly headroom near its reset, idle 5h window: 5000 * 0.47 / 48 = 49.
    ([0.0, 0.53], [Double?.some(5), .some(48)],
     SteerWeight.Decision.weight(49, reason: "weekly 47% free, reset in 48.0h, 5h 0% used")),
    // The 5-hour window scales the weight by (0.90 - used) / 0.90.
    ([0.45, 0.53], [Double?.some(5), .some(48)],
     .weight(24, reason: "weekly 47% free, reset in 48.0h, 5h 45% used")),
    // The 5-hour gate.
    ([0.90, 0.10], [Double?.some(1), .some(10)], .weight(1, reason: "5h 90% used")),
    ([0.20, 0.95], [Double?.some(1), .some(10)], .weight(1, reason: "weekly 95% used")),
    // A burn rate that spends the headroom before the reset is damped:
    // 0.72 used in 60h projects 1.30 over 108h, so x 0.28 / 1.30.
    ([0.30, 0.72], [Double?.some(2), .some(108)],
     .weight(2, reason: "weekly 28% free, reset in 108.0h, 5h 30% used, burn x0.22")),
    // Under 24h into the week the burn rate is not trusted.
    ([0.0, 0.30], [Double?.some(5), .some(150)],
     .weight(23, reason: "weekly 70% free, reset in 150.0h, 5h 0% used")),
    // A weekly reset under 5h uses the 5-hour floor.
    ([0.0, 0.0], [Double?.some(1), .some(1)], .weight(1000, reason: "weekly 100% free, reset in 5.0h, 5h 0% used")),
    // No weekly reset time: a full week away.
    ([0.0, 0.0], [Double?.some(1), .none], .weight(30, reason: "weekly 100% free, reset in 168.0h, 5h 0% used")),
    // A team seat with no weekly window falls back to the tightest rule.
    ([0.5], [Double?.some(1)], .weight(125, reason: "50% free, reset in 1.0h")),
])
func weeklyRule(used: [Double], hours: [Double?], expected: SteerWeight.Decision) {
    #expect(SteerWeight.decide(member("a@x", used: used, resetsIn: hours), now: now, basis: .weekly) == expected)
}

/// Live numbers from 2026-11-03. Under the tightest rule alice got 2 because
/// her 5-hour window was idle, while bob, busy in his 5-hour window, got 31.
@Test func weeklyHeadroomResettingSoonOutweighsBusyFiveHourWindow() {
    let alice = member("alice@x", used: [0.0, 0.53], resetsIn: [5, 48])
    let bob = member("bob@x", used: [0.75, 0.09], resetsIn: [1.2, 163])
    guard case .weight(let aliceWeight, _) = SteerWeight.decide(alice, now: now, basis: .weekly),
          case .weight(let bobWeight, _) = SteerWeight.decide(bob, now: now, basis: .weekly)
    else { Issue.record("expected weights"); return }
    #expect(aliceWeight > bobWeight)
    #expect(aliceWeight == 49)
    #expect(bobWeight == 5)
}

@Test func basisDefaultsToEDF() {
    let alice = member("alice@x", used: [0.0, 0.53], resetsIn: [5, 48])
    #expect(SteerWeight.decide(alice, now: now) == SteerWeight.decide(alice, now: now, basis: .edf))
    #expect(SteerWeight.decide([alice], now: now) == [SteerWeight.decide(alice, now: now, basis: .edf)])
    #expect(SteerWeight.Basis(rawValue: "edf") == .edf)
    #expect(SteerWeight.Basis(rawValue: "tightest") == .tightest)
    #expect(SteerWeight.Basis(rawValue: "soonest") == nil)
}

// MARK: - Tightest weight rule

@Test(arguments: [
    // used, hours until reset, expected
    ([0.0], [Double?.some(0.25)], SteerWeight.Decision.weight(1000, reason: "100% free, reset in 0.2h")),
    ([0.5], [Double?.some(1)], .weight(125, reason: "50% free, reset in 1.0h")),
    ([0.3], [Double?.some(4)], .weight(44, reason: "70% free, reset in 4.0h")),
    ([0.94], [Double?.some(5)], .weight(3, reason: "6% free, reset in 5.0h")),
    ([0.95], [Double?.some(0.5)], .weight(1, reason: "95% used")),
    ([1.0], [Double?.some(0.5)], .weight(1, reason: "100% used")),
    // A reset that has passed uses the 15-minute floor.
    ([0.2], [Double?.some(-1)], .weight(800, reason: "80% free, reset in 0.2h")),
    // The tightest window sets the headroom; the soonest reset sets the hours.
    ([0.2, 0.6], [Double?.some(2), .some(100)], .weight(50, reason: "40% free, reset in 2.0h")),
    ([0.1, 0.97], [Double?.some(2), .some(100)], .weight(1, reason: "97% used")),
    // No reset time: treated as a week away, clamped to the minimum.
    ([0.0], [Double?.none], .weight(1, reason: "100% free, reset in 168.0h")),
])
func tightestRule(used: [Double], hours: [Double?], expected: SteerWeight.Decision) {
    #expect(SteerWeight.decide(member("a@x", used: used, resetsIn: hours), now: now, basis: .tightest) == expected)
}

@Test func soonerResetWithEqualHeadroomWeighsMore() {
    let soon = SteerWeight.decide(member("a@x", used: [0.4], resetsIn: [1]), now: now, basis: .tightest)
    let late = SteerWeight.decide(member("b@x", used: [0.4], resetsIn: [4]), now: now, basis: .tightest)
    guard case .weight(let soonWeight, _) = soon, case .weight(let lateWeight, _) = late else {
        Issue.record("expected weights"); return
    }
    #expect(soonWeight > lateWeight)
}

@Test(arguments: [
    (UsageAccountState.error, "HTTP 429: rate limited", SteerWeight.Decision.weight(1, reason: "cooling down")),
    (.error, "rate limited, cooling down for ~4m", .weight(1, reason: "cooling down")),
    (.error, "proxy HTTP 500", .keep(reason: "no fresh reading (error)")),
    (.stale, "timed out", .keep(reason: "no fresh reading (stale)")),
    (.signedOut, nil, .keep(reason: "no fresh reading (signedOut)")),
] as [(UsageAccountState, String?, SteerWeight.Decision)])
func unreadableMembers(state: UsageAccountState, detail: String?, expected: SteerWeight.Decision) {
    for basis in SteerWeight.Basis.allCases {
        #expect(SteerWeight.decide(member("a@x", state: state, detail: detail), now: now, basis: basis) == expected)
    }
}

// MARK: - Plan

private func snapshot(age: TimeInterval, members: [UsageAccount]) -> UsageSnapshot {
    UsageSnapshot(
        generatedAt: now.addingTimeInterval(-age),
        accounts: [UsageAccount(id: "cc3", provider: .claude, displayName: "cc3", state: .ok, members: members)])
}

private let entries = [
    ProxySteer.AuthEntry(name: "claude-a.json", provider: "claude", email: "A@x", weight: 7),
    ProxySteer.AuthEntry(name: "claude-b.json", provider: "claude", email: "b@x"),
    ProxySteer.AuthEntry(name: "claude-d.json", provider: "claude", email: "d@x", disabled: true),
    ProxySteer.AuthEntry(name: "codex-c.json", provider: "codex", email: "c@x"),
]

@Test func planMatchesMembersToLoginsByEmail() throws {
    let rows = try ProxySteer.plan(
        snapshot: snapshot(age: 60, members: [
            member("a@x", used: [0.5], resetsIn: [1]),
            member("b@x", state: .stale, detail: "timed out"),
            member("c@x", used: [0.1], resetsIn: [1]),
            member("d@x", used: [0.1], resetsIn: [1]),
        ]),
        poolID: "cc3", entries: entries, now: now, basis: .tightest)
    #expect(rows == [
        .init(email: "a@x", name: "claude-a.json", currentWeight: 7, newWeight: 125, reason: "50% free, reset in 1.0h"),
        .init(email: "b@x", name: "claude-b.json", currentWeight: nil, newWeight: nil, reason: "no fresh reading (stale)"),
        // A login of another provider, or a disabled one, is not a match.
        .init(email: "c@x", name: nil, currentWeight: nil, newWeight: nil, reason: "no proxy login"),
        .init(email: "d@x", name: nil, currentWeight: nil, newWeight: nil, reason: "no proxy login"),
    ])
    #expect(rows.map(\.needsUpdate) == [true, false, false, false])
}

@Test func planPassesTheBasisThrough() throws {
    let snap = snapshot(age: 60, members: [member("a@x", used: [0.0, 0.53], resetsIn: [5, 48])])
    let tightest = try ProxySteer.plan(snapshot: snap, poolID: "cc3", entries: entries, now: now, basis: .tightest)
    let edf = try ProxySteer.plan(snapshot: snap, poolID: "cc3", entries: entries, now: now)
    let weekly = try ProxySteer.plan(snapshot: snap, poolID: "cc3", entries: entries, now: now, basis: .weekly)
    #expect(edf.map(\.newWeight) == [470])
    #expect(weekly.map(\.newWeight) == [49])
    #expect(tightest.map(\.newWeight) == [24])
}

@Test func matchingListedWeightNeedsNoUpdate() {
    let row = ProxySteer.Row(email: "a@x", name: "claude-a.json", currentWeight: 9, newWeight: 9, reason: "")
    #expect(!row.needsUpdate)
}

@Test func staleSnapshotChangesNothing() {
    #expect(throws: ProxySteer.PlanError.staleSnapshot(ageSeconds: 15 * 60 + 1)) {
        try ProxySteer.plan(
            snapshot: snapshot(age: 15 * 60 + 1, members: [member("a@x", used: [0.1], resetsIn: [1])]),
            poolID: "cc3", entries: entries, now: now)
    }
}

@Test func missingPoolChangesNothing() {
    #expect(throws: ProxySteer.PlanError.noPool("cc9")) {
        try ProxySteer.plan(
            snapshot: snapshot(age: 0, members: [member("a@x", used: [0.1], resetsIn: [1])]),
            poolID: "cc9", entries: entries, now: now)
    }
}

// MARK: - Management API

@Test func listingKeepsOnlyNamesEmailsAndWeights() {
    let listing = #"{"files":[{"name":"claude-a.json","provider":"claude","email":"a@x","disabled":false,"weight":12,"auth_index":"i1","status":"active"},{"name":"codex-b.json","provider":"codex","email":"b@x","disabled":true},{"provider":"claude"}]}"#
    #expect(ProxySteer.authEntries(fromListing: Data(listing.utf8)) == [
        .init(name: "claude-a.json", provider: "claude", email: "a@x", weight: 12),
        .init(name: "codex-b.json", provider: "codex", email: "b@x", disabled: true),
    ])
    #expect(ProxySteer.authEntries(fromListing: Data("not json".utf8)).isEmpty)
}

@Test func weightRequestPatchesOnlyTheWeight() throws {
    let request = ProxySteer.weightRequest(base: "http://127.0.0.1:8317", key: "k", name: "claude-a.json", weight: 42)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.absoluteString == "http://127.0.0.1:8317/v0/management/auth-files/fields")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == #"{"name":"claude-a.json","weight":42}"#)
}

// MARK: - Output

@Test func tableShowsEmailsAndWeightsOnly() {
    let table = ProxySteer.table([
        .init(email: "a@x", name: "claude-a.json", currentWeight: 7, newWeight: 125, reason: "50% free, reset in 1.0h"),
        .init(email: "longer@x", name: nil, currentWeight: nil, newWeight: nil, reason: "no proxy login"),
    ])
    #expect(table == """
    EMAIL     NOW    NEW    WHY
    a@x       7      125    50% free, reset in 1.0h
    longer@x  -      keep   no proxy login
    """)
}
