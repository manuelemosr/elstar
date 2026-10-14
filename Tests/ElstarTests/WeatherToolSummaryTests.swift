import Foundation
import Testing

@testable import Elstar

/// (a) + (b): the weather tool result must lead with the day the person asked
/// about and state exactly which days were fetched, so the model cannot
/// relabel today's numbers as tomorrow.
@Suite("Weather tool text: requested day and fetched window")
struct WeatherToolSummaryTests {
    private let timeZone = TimeZone(identifier: "Europe/Amsterdam")!

    private func day(_ offset: Int, label: String, high: Double, low: Double, condition: String = "Mostly Cloudy") -> AppleWeatherDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 46))!
        return AppleWeatherDay(
            day: label,
            condition: condition,
            highCelsius: high,
            lowCelsius: low,
            date: calendar.date(byAdding: .day, value: offset, to: base)
        )
    }

    private func snapshot(forecast: [AppleWeatherDay]) -> AppleWeatherSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let observedAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 46))!
        return AppleWeatherSnapshot(
            locationName: "Amsterdam",
            condition: "Mostly Cloudy",
            temperatureCelsius: 18,
            highCelsius: 18,
            lowCelsius: 10,
            forecast: forecast,
            attributionText: "Weather data by Apple Weather",
            observedAt: observedAt,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    private func execute(_ request: AppleWeatherRequest, snapshot: AppleWeatherSnapshot) async -> AppleToolResult? {
        let weather = FakeWeatherService()
        weather.snapshot = snapshot
        let executor = AppleToolExecutor(
            key: HarnessConversationKey(absoluteKey: "conn/turn"),
            messageID: "m1",
            tracker: RecordingTracker(),
            sink: RecordingEventSink(),
            serializer: AppleOperationSerializer(),
            confirmations: AppleConfirmationStore(),
            journal: AppleToolJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")),
            services: .fake(weather: weather),
            clock: FixedAppleClock(snapshot.observedAt ?? Date(timeIntervalSince1970: 0))
        )
        return await executor.perform(.weather(request))
    }

    @Test("A highlighted day leads the text with its own high/low and the window")
    func highlightedDayLeads() async {
        let forecast = [
            day(0, label: "Today Wed 14 Oct", high: 18, low: 10),
            day(1, label: "Tomorrow Thu 15 Oct", high: 20, low: 11),
        ]
        let request = AppleWeatherRequest(anchor: .currentLocation, kind: .forecast(days: 2), highlightDay: 1)
        guard let result = await execute(request, snapshot: snapshot(forecast: forecast)) else {
            Issue.record("no weather result"); return
        }
        #expect(result.summary.contains("18°C now"))
        #expect(result.summary.contains("Tomorrow Thu 15 Oct: Mostly Cloudy, H 20° L 11°"))
        #expect(result.summary.contains("Days fetched: Today Wed 14 Oct; Tomorrow Thu 15 Oct"))
        // The unlabelled today headline must not be the subject any more.
        #expect(!result.summary.contains("H 18° L 10°)"))
        #expect(result.weatherPresentation?.highlightedDate != nil)
    }

    @Test("A single fetched day says so explicitly so no other day can be described")
    func singleDayIsCalledOut() async {
        let forecast = [day(0, label: "Today Wed 14 Oct", high: 18, low: 10)]
        let request = AppleWeatherRequest(anchor: .currentLocation, kind: .forecast(days: 1))
        guard let result = await execute(request, snapshot: snapshot(forecast: forecast)) else {
            Issue.record("no weather result"); return
        }
        #expect(result.summary.contains("Today Wed 14 Oct: Mostly Cloudy, H 18° L 10°"))
        #expect(result.summary.contains("Days fetched: Today Wed 14 Oct"))
        #expect(result.summary.contains("only this day is available; do not describe any other day"))
    }

    @Test("Current conditions with no forecast keep the plain headline")
    func currentOnlyKeepsPlainHeadline() async {
        let request = AppleWeatherRequest(anchor: .currentLocation, kind: .current)
        guard let result = await execute(request, snapshot: snapshot(forecast: [])) else {
            Issue.record("no weather result"); return
        }
        #expect(result.summary == "Amsterdam: Mostly Cloudy, 18°C (H 18° L 10°). Weather data by Apple Weather.")
        #expect(!result.summary.contains("Days fetched"))
    }
}
