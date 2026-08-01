import Foundation
import Testing
import UsageModels
@testable import UsageFetch

@Test func windowLabelsDeriveFromSeconds() {
    #expect(CodexClient.label(forWindowSeconds: 18_000) == "5h")
    #expect(CodexClient.label(forWindowSeconds: 604_800) == "7d")
    #expect(CodexClient.label(forWindowSeconds: 3_600) == "1h")
    #expect(CodexClient.label(forWindowSeconds: 0) == "—")
}

@Test func usedPercentClampsAndRounds() {
    #expect(UsageWindow(label: "5h", usedFraction: 0.094).usedPercent == 9)
    #expect(UsageWindow(label: "5h", usedFraction: 1.4).usedPercent == 100)
    #expect(UsageWindow(label: "5h", usedFraction: -0.2).usedPercent == 0)
}

@Test func worstWindowPicksTheFullestOne() {
    let account = UsageAccount(
        id: "cc1", provider: .claude, displayName: "cc1", state: .ok,
        windows: [
            UsageWindow(label: "5h", usedFraction: 0.09),
            UsageWindow(label: "7d", usedFraction: 0.62),
        ])
    #expect(account.worstWindow?.label == "7d")
}

@Test func iso8601ParsesBothFractionalAndPlainForms() {
    // Anthropic sends fractional seconds; Google does not.
    #expect(Date.fromISO8601("2026-08-06T20:00:00.027245+00:00") != nil)
    #expect(Date.fromISO8601("2026-08-03T14:02:16Z") != nil)
    #expect(Date.fromISO8601("not a date") == nil)
}

@Test func snapshotSurvivesAWireRoundTrip() throws {
    let snapshot = UsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_785_575_910), accounts: [
        UsageAccount(
            id: "agy1", provider: .antigravity, displayName: "agy1", state: .ok,
            windows: [UsageWindow(group: "Gemini Models", label: "weekly", usedFraction: 0.0135)]),
        UsageAccount(id: "cc2", provider: .claude, displayName: "cc2", state: .signedOut),
    ])
    let data = try UsageSnapshot.encoder().encode(snapshot)
    let decoded = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: data)
    #expect(decoded == snapshot)
    #expect(decoded.accounts[0].windows[0].group == "Gemini Models")
    #expect(decoded.accounts[1].state == .signedOut)
}

@Test func bundledConfigCoversEveryConfiguredAccount() {
    let config = Config.bundled
    #expect(config.accounts.count == 6)
    #expect(config.accounts.filter { $0.provider == .claude }.allSatisfy { $0.keychainService != nil })
    #expect(config.accounts.filter { $0.provider == .codex }.allSatisfy { $0.codexHome != nil })
    #expect(config.accounts.filter { $0.provider == .antigravity }.allSatisfy { $0.home != nil })
}
