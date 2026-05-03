import Testing
import Foundation
@testable import ClaudeUsage

// MARK: - UsageLimit.color

@Test func colorIsSafeBelow70() {
    #expect(UsageLimit(utilization: 0, resetAt: nil).color == .safe)
    #expect(UsageLimit(utilization: 69.99, resetAt: nil).color == .safe)
}

@Test func colorIsWarningAt70Through89() {
    #expect(UsageLimit(utilization: 70, resetAt: nil).color == .warning)
    #expect(UsageLimit(utilization: 89.99, resetAt: nil).color == .warning)
}

@Test func colorIsCriticalAt90AndAbove() {
    #expect(UsageLimit(utilization: 90, resetAt: nil).color == .critical)
    #expect(UsageLimit(utilization: 100, resetAt: nil).color == .critical)
}

// MARK: - UsageLimit.percentage (truncates toward zero)

@Test func percentageTruncatesFractionalUtilization() {
    #expect(UsageLimit(utilization: 0, resetAt: nil).percentage == 0)
    #expect(UsageLimit(utilization: 49.9, resetAt: nil).percentage == 49)
    #expect(UsageLimit(utilization: 99.9999, resetAt: nil).percentage == 99)
    #expect(UsageLimit(utilization: 100, resetAt: nil).percentage == 100)
}

// MARK: - UsageLimit.resetDescription

@Test func resetDescriptionUnknownWhenNilReset() {
    #expect(UsageLimit(utilization: 50, resetAt: nil).resetDescription == "Unknown")
}

@Test func resetDescriptionResettingWhenInPast() {
    let past = Date(timeIntervalSinceNow: -60)
    #expect(UsageLimit(utilization: 50, resetAt: past).resetDescription == "Resetting...")
}

@Test func resetDescriptionFormatsMinutesUnderOneHour() {
    let inFifteenMin = Date(timeIntervalSinceNow: 15 * 60 + 5) // small buffer
    let desc = UsageLimit(utilization: 50, resetAt: inFifteenMin).resetDescription
    #expect(desc.hasPrefix("Resets in"))
    #expect(desc.contains("min"))
    #expect(!desc.contains("hr"))
}

@Test func resetDescriptionFormatsHoursAndMinutes() {
    let inTwoHoursThirty = Date(timeIntervalSinceNow: 2 * 3600 + 30 * 60 + 5)
    let desc = UsageLimit(utilization: 50, resetAt: inTwoHoursThirty).resetDescription
    #expect(desc.contains("hr"))
    #expect(desc.contains("min"))
}

// MARK: - UsageAPIResponse.toDomain

@Test func toDomainParsesISO8601Timestamps() {
    let json = """
    {
        "five_hour": {"utilization": 42.5, "resets_at": "2026-05-03T18:00:00.000Z"},
        "seven_day": {"utilization": 17.0, "resets_at": "2026-05-10T00:00:00.000Z"},
        "seven_day_sonnet": {"utilization": 5.0, "resets_at": "2026-05-10T00:00:00.000Z"}
    }
    """
    let decoded = try! JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    let domain = decoded.toDomain()

    #expect(domain.session.utilization == 42.5)
    #expect(domain.session.resetAt != nil)
    #expect(domain.weeklyAll.utilization == 17.0)
    #expect(domain.weeklySonnet?.utilization == 5.0)
}

@Test func toDomainHandlesMissingSonnet() {
    let json = """
    {
        "five_hour": {"utilization": 10.0, "resets_at": null},
        "seven_day": {"utilization": 20.0, "resets_at": null}
    }
    """
    let decoded = try! JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    let domain = decoded.toDomain()

    #expect(domain.weeklySonnet == nil)
    #expect(domain.session.resetAt == nil)
    #expect(domain.weeklyAll.resetAt == nil)
}

// MARK: - AppState.menuBarText

@MainActor
@Test func menuBarTextShowsPlaceholderUntilFirstUpdate() {
    let state = AppState()
    state.isConfigured = false
    #expect(state.menuBarText == "⚡ --")

    state.isConfigured = true
    // usage still .empty (lastUpdated == .distantPast)
    #expect(state.menuBarText == "⚡ --")
}

@MainActor
@Test func menuBarTextShowsSessionPercentageWhenLoaded() {
    let state = AppState()
    state.isConfigured = true
    state.usage = ClaudeUsageData(
        session: UsageLimit(utilization: 73, resetAt: nil),
        weeklyAll: UsageLimit(utilization: 0, resetAt: nil),
        weeklySonnet: nil,
        lastUpdated: Date()
    )
    #expect(state.menuBarText == "⚡ 73%")
}
