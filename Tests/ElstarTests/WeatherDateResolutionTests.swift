import Testing
import Foundation
@testable import Elstar

@Suite("Weather date resolution")
struct WeatherDateResolutionTests {

    /// Wednesday, October 21, 2026 at 11:47 Europe/Amsterdam
    private static let wednesday: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 11, minute: 47))!
    }()
    private static let amsterdam = Calendar(identifier: .gregorian)

    @Test("Weekday name resolves to correct offset")
    func weekdayName() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // Wednesday -> Saturday = 3 days
        let resolved = AppleWeatherDateResolution.resolve("Saturday", now: Self.wednesday, calendar: cal)
        #expect(resolved?.dayOffset == 3)
        #expect(resolved?.daysNeeded == 4)

        // Wednesday -> Friday = 2 days
        let friday = AppleWeatherDateResolution.resolve("Friday", now: Self.wednesday, calendar: cal)
        #expect(friday?.dayOffset == 2)
        #expect(friday?.daysNeeded == 3)

        // Wednesday -> Wednesday (today) = 0 days
        let today = AppleWeatherDateResolution.resolve("Wednesday", now: Self.wednesday, calendar: cal)
        #expect(today?.dayOffset == 0)
        #expect(today?.daysNeeded == 1)

        // Wednesday -> Sunday = 4 days
        let sunday = AppleWeatherDateResolution.resolve("Sunday", now: Self.wednesday, calendar: cal)
        #expect(sunday?.dayOffset == 4)
        #expect(sunday?.daysNeeded == 5)
    }

    @Test("Weekday name is case-insensitive")
    func weekdayCaseInsensitive() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        #expect(AppleWeatherDateResolution.resolve("saturday", now: Self.wednesday, calendar: cal)?.dayOffset == 3)
        #expect(AppleWeatherDateResolution.resolve("SATURDAY", now: Self.wednesday, calendar: cal)?.dayOffset == 3)
        #expect(AppleWeatherDateResolution.resolve("Sat", now: Self.wednesday, calendar: cal)?.dayOffset == 3)
    }

    @Test("ISO date resolves to correct offset")
    func isoDate() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // Wednesday Oct 21 -> Saturday Oct 24 = 3 days
        let resolved = AppleWeatherDateResolution.resolve("2026-10-24", now: Self.wednesday, calendar: cal)
        #expect(resolved?.dayOffset == 3)
        #expect(resolved?.daysNeeded == 4)

        // Wednesday Oct 21 -> Wednesday Oct 21 (today) = 0 days
        let today = AppleWeatherDateResolution.resolve("2026-10-21", now: Self.wednesday, calendar: cal)
        #expect(today?.dayOffset == 0)
        #expect(today?.daysNeeded == 1)
    }

    @Test("Now means current conditions without requesting daily forecasts")
    func nowKeepsCurrentConditions() {
        let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil,
            args: DeviceAgentArguments(date: "now"), clock: FixedAppleClock(Self.wednesday), calendar: Self.amsterdam)
        guard case .request(.weather(let request)) = conversion else { Issue.record("Expected weather request"); return }
        #expect(request.kind == .current)
        #expect(request.highlightDay == nil)
    }

    @Test("Relative phrases resolve correctly")
    func relativePhrases() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let tomorrow = AppleWeatherDateResolution.resolve("tomorrow", now: Self.wednesday, calendar: cal)
        #expect(tomorrow?.dayOffset == 1)
        #expect(tomorrow?.daysNeeded == 2)

        let today = AppleWeatherDateResolution.resolve("today", now: Self.wednesday, calendar: cal)
        #expect(today?.dayOffset == 0)
        #expect(today?.daysNeeded == 1)
    }

    @Test("Past dates return nil")
    func pastDate() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // Wednesday Oct 21 -> Tuesday Oct 20 (yesterday)
        #expect(AppleWeatherDateResolution.resolve("2026-10-20", now: Self.wednesday, calendar: cal) == nil)
        #expect(AppleWeatherDateResolution.resolve("2026-11-20", now: Self.wednesday, calendar: cal) == nil)
    }

    @Test("An explicit today overrides an inconsistent future highlight")
    func todayOverridesHighlight() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil,
            args: DeviceAgentArguments(date: "today", highlightDay: 3), clock: FixedAppleClock(Self.wednesday), calendar: cal)
        guard case .request(.weather(let request)) = conversion else { Issue.record("Expected weather request"); return }
        #expect(request.highlightDay == 0)
        #expect(request.kind == .forecast(days: 1))
    }

    @Test("Unrecognized input returns nil")
    func unrecognized() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        #expect(AppleWeatherDateResolution.resolve("next week", now: Self.wednesday, calendar: cal) == nil)
        #expect(AppleWeatherDateResolution.resolve("", now: Self.wednesday, calendar: cal) == nil)
        #expect(AppleWeatherDateResolution.resolve(nil, now: Self.wednesday, calendar: cal) == nil)
        #expect(AppleWeatherDateResolution.resolve("not a date", now: Self.wednesday, calendar: cal) == nil)
    }

    @Test("Same weekday resolves to today (offset 0)")
    func sameWeekdayIsToday() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // On Wednesday, asking for Wednesday means today
        let resolved = AppleWeatherDateResolution.resolve("Wednesday", now: Self.wednesday, calendar: cal)
        #expect(resolved?.dayOffset == 0)
        #expect(resolved?.daysNeeded == 1)
    }

    @Test("Weather converter uses date parameter over days/highlightDay")
    func converterUsesDate() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let clock = FixedAppleClock(Self.wednesday)
        // Model passes date: "Saturday" with days: 3 (wrong). Date should win.
        let args = DeviceAgentArguments(date: "Saturday", days: 3)
        let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil, args: args, clock: clock, calendar: cal)
        guard case .request(let request) = conversion else {
            Issue.record("Expected a request, got \(conversion)")
            return
        }
        guard case .weather(let weatherRequest) = request else {
            Issue.record("Expected a weather request")
            return
        }
        // Saturday from Wednesday = offset 3, needs 4 days
        #expect(weatherRequest.highlightDay == 3)
        if case .forecast(let days) = weatherRequest.kind {
            #expect(days == 4)
        } else {
            Issue.record("Expected forecast kind")
        }
    }

    @Test("Weather converter rejects unrecognized date")
    func converterRejectsBadDate() {
        var cal = Self.amsterdam
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let clock = FixedAppleClock(Self.wednesday)
        let args = DeviceAgentArguments(date: "not a date")
        let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil, args: args, clock: clock, calendar: cal)
        guard case .askUser = conversion else {
            Issue.record("Expected askUser for bad date, got \(conversion)")
            return
        }
    }
}
