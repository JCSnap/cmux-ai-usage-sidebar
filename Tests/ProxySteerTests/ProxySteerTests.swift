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

// MARK: - Weight rule

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
func weightRule(used: [Double], hours: [Double?], expected: SteerWeight.Decision) {
    #expect(SteerWeight.decide(member("a@x", used: used, resetsIn: hours), now: now) == expected)
}

@Test func soonerResetWithEqualHeadroomWeighsMore() {
    let soon = SteerWeight.decide(member("a@x", used: [0.4], resetsIn: [1]), now: now)
    let late = SteerWeight.decide(member("b@x", used: [0.4], resetsIn: [4]), now: now)
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
    #expect(SteerWeight.decide(member("a@x", state: state, detail: detail), now: now) == expected)
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
        poolID: "cc3", entries: entries, now: now)
    #expect(rows == [
        .init(email: "a@x", name: "claude-a.json", currentWeight: 7, newWeight: 125, reason: "50% free, reset in 1.0h"),
        .init(email: "b@x", name: "claude-b.json", currentWeight: nil, newWeight: nil, reason: "no fresh reading (stale)"),
        // A login of another provider, or a disabled one, is not a match.
        .init(email: "c@x", name: nil, currentWeight: nil, newWeight: nil, reason: "no proxy login"),
        .init(email: "d@x", name: nil, currentWeight: nil, newWeight: nil, reason: "no proxy login"),
    ])
    #expect(rows.map(\.needsUpdate) == [true, false, false, false])
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
