import Testing
import Foundation
@testable import Elstar

@Suite("Weather presentation")
struct WeatherPresentationTests {

    @Test("A weather presentation stored before the weather fields decodes with nil additions")
    func legacyPresentationDecodes() throws {
        let json = Data("""
        {"locationName":"Cupertino","attributionText":"Weather data by Apple Weather"}
        """.utf8)
        let presentation = try JSONDecoder().decode(AppleWeatherPresentation.self, from: json)
        #expect(presentation.locationName == "Cupertino")
        #expect(presentation.attributionText == "Weather data by Apple Weather")
        #expect(presentation.condition == nil)
        #expect(presentation.temperatureCelsius == nil)
        #expect(presentation.highCelsius == nil)
        #expect(presentation.lowCelsius == nil)
        #expect(presentation.symbolName == nil)
        #expect(presentation.isDaylight == nil)
        #expect(presentation.observedAt == nil)
        #expect(presentation.timeZoneIdentifier == nil)
        #expect(presentation.forecast == nil)
        #expect(presentation.highlightedDate == nil)
    }

    @Test("A full weather presentation survives ToolActivity JSON encode/decode")
    func fullPresentationRoundTripsThroughToolActivity() throws {
        let observedAt = Date(timeIntervalSince1970: 1_759_449_600)
        let dayOneDate = Date(timeIntervalSince1970: 1_759_449_600)
        let dayTwoDate = Date(timeIntervalSince1970: 1_759_536_000)
        let presentation = AppleWeatherPresentation(
            locationName: "Cupertino",
            attributionText: "Weather data by Apple Weather",
            attributionURL: URL(string: "https://weather.com/en-US/legal"),
            condition: "Clear",
            temperatureCelsius: 21,
            highCelsius: 25,
            lowCelsius: 14,
            symbolName: "sun.max.fill",
            isDaylight: true,
            observedAt: observedAt,
            timeZoneIdentifier: "Europe/Lisbon",
            forecast: [
                AppleWeatherDay(day: "Fri 2 Oct", condition: "Clear", highCelsius: 25, lowCelsius: 14, date: dayOneDate, symbolName: "sun.max", precipitationChance: 0.1, windSpeedKPH: 12.5, uvIndex: 6),
                AppleWeatherDay(day: "Sat 3 Oct", condition: "Rain", highCelsius: 20, lowCelsius: 12, date: dayTwoDate, symbolName: "cloud.rain", precipitationChance: 0.8, windSpeedKPH: 20.0, uvIndex: 3)
            ],
            highlightedDate: dayTwoDate
        )
        let activity = ToolActivity(id: "t1", name: "weather", status: .completed, weatherPresentation: presentation)
        let data = try JSONEncoder().encode(activity)
        let decoded = try JSONDecoder().decode(ToolActivity.self, from: data)
        #expect(decoded == activity)
        #expect(decoded.weatherPresentation?.condition == "Clear")
        #expect(decoded.weatherPresentation?.temperatureCelsius == 21)
        #expect(decoded.weatherPresentation?.highCelsius == 25)
        #expect(decoded.weatherPresentation?.lowCelsius == 14)
        #expect(decoded.weatherPresentation?.symbolName == "sun.max.fill")
        #expect(decoded.weatherPresentation?.isDaylight == true)
        #expect(decoded.weatherPresentation?.attributionURL == URL(string: "https://weather.com/en-US/legal"))
        #expect(decoded.weatherPresentation?.observedAt == observedAt)
        #expect(decoded.weatherPresentation?.timeZoneIdentifier == "Europe/Lisbon")
        #expect(decoded.weatherPresentation?.highlightedDate == dayTwoDate)
        let forecast = decoded.weatherPresentation?.forecast ?? []
        #expect(forecast.count == 2)
        #expect(forecast[0].date == dayOneDate)
        #expect(forecast[0].symbolName == "sun.max")
        #expect(forecast[0].precipitationChance == 0.1)
        #expect(forecast[0].windSpeedKPH == 12.5)
        #expect(forecast[0].uvIndex == 6)
        #expect(forecast[1].date == dayTwoDate)
        #expect(forecast[1].symbolName == "cloud.rain")
        #expect(forecast[1].precipitationChance == 0.8)
        #expect(forecast[1].windSpeedKPH == 20.0)
        #expect(forecast[1].uvIndex == 3)
    }

    @Test("A weather read carries the snapshot's actual weather into the completed delta")
    func weatherReadPlumbsSnapshotIntoPresentation() async {
        let weather = FakeWeatherService()
        let observedAt = Date(timeIntervalSince1970: 1_759_449_600)
        let dayOneDate = Date(timeIntervalSince1970: 1_759_449_600)
        let dayTwoDate = Date(timeIntervalSince1970: 1_759_536_000)
        let forecast = [
            AppleWeatherDay(day: "Today Fri 2 Oct", condition: "Clear", highCelsius: 25, lowCelsius: 14, date: dayOneDate, symbolName: "sun.max", precipitationChance: 0.1, windSpeedKPH: 12.5, uvIndex: 6),
            AppleWeatherDay(day: "Tomorrow Sat 3 Oct", condition: "Rain", highCelsius: 20, lowCelsius: 12, date: dayTwoDate, symbolName: "cloud.rain", precipitationChance: 0.8, windSpeedKPH: 20.0, uvIndex: 3)
        ]
        weather.snapshot = AppleWeatherSnapshot(
            locationName: "Cupertino",
            condition: "Clear",
            temperatureCelsius: 21,
            highCelsius: 25,
            lowCelsius: 14,
            forecast: forecast,
            attributionText: "Weather data by Apple Weather",
            symbolName: "sun.max.fill",
            isDaylight: true,
            observedAt: observedAt,
            timeZoneIdentifier: "Europe/Lisbon"
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let sink = RecordingEventSink()
        let executor = AppleToolExecutor(
            key: HarnessConversationKey(absoluteKey: "conn/turn"),
            messageID: "m1",
            tracker: RecordingTracker(),
            sink: sink,
            serializer: AppleOperationSerializer(),
            confirmations: AppleConfirmationStore(),
            journal: AppleToolJournal(fileURL: url),
            services: .fake(weather: weather),
            clock: FixedAppleClock(Date(timeIntervalSince1970: 0))
        )

        let result = await executor.perform(.weather(AppleWeatherRequest(anchor: .currentLocation, kind: .current)))
        let expected = AppleWeatherPresentation(
            locationName: "Cupertino",
            attributionText: "Weather data by Apple Weather",
            condition: "Clear",
            temperatureCelsius: 21,
            highCelsius: 25,
            lowCelsius: 14,
            symbolName: "sun.max.fill",
            isDaylight: true,
            observedAt: observedAt,
            timeZoneIdentifier: "Europe/Lisbon",
            forecast: forecast
        )
        #expect(result?.weatherPresentation == expected)
        #expect(result?.receipt == nil)
        #expect(sink.interactions.isEmpty)
        #expect(sink.receipts.isEmpty)
        #expect(sink.deltas.map(\.status) == [.running, .completed])
        #expect(sink.deltas.last?.weatherPresentation == result?.weatherPresentation)
    }

    @Test("A stored AppleWeatherDay written before the metric fields decodes with nil additions")
    func legacyWeatherDayDecodes() throws {
        let json = Data("""
        {"day":"Fri 2 Oct","condition":"Clear","highCelsius":25,"lowCelsius":14}
        """.utf8)
        let day = try JSONDecoder().decode(AppleWeatherDay.self, from: json)
        #expect(day.day == "Fri 2 Oct")
        #expect(day.condition == "Clear")
        #expect(day.highCelsius == 25)
        #expect(day.lowCelsius == 14)
        #expect(day.date == nil)
        #expect(day.symbolName == nil)
        #expect(day.precipitationChance == nil)
        #expect(day.windSpeedKPH == nil)
        #expect(day.uvIndex == nil)
    }

    private func preferredDayFixture(forecast: [AppleWeatherDay]) -> (FakeWeatherService, Date) {
        let observedAt = Date(timeIntervalSince1970: 1_759_449_600)
        let weather = FakeWeatherService()
        weather.snapshot = AppleWeatherSnapshot(
            locationName: "Cupertino",
            condition: "Clear",
            temperatureCelsius: 21,
            highCelsius: 25,
            lowCelsius: 14,
            forecast: forecast,
            attributionText: "Weather data by Apple Weather",
            symbolName: "sun.max.fill",
            isDaylight: true,
            observedAt: observedAt,
            timeZoneIdentifier: "Europe/Lisbon"
        )
        return (weather, observedAt)
    }

    private func makeExecutor(for weather: FakeWeatherService) -> AppleToolExecutor {
        AppleToolExecutor(
            key: HarnessConversationKey(absoluteKey: "conn/turn"),
            messageID: "m1",
            tracker: RecordingTracker(),
            sink: RecordingEventSink(),
            serializer: AppleOperationSerializer(),
            confirmations: AppleConfirmationStore(),
            journal: AppleToolJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")),
            services: .fake(weather: weather),
            clock: FixedAppleClock(Date(timeIntervalSince1970: 0))
        )
    }

    @Test("A preferred weather day highlights the real tomorrow date, not the array position")
    func preferredWeatherDayHighlightsActualTomorrowDate() async {
        let dayOneDate = Date(timeIntervalSince1970: 1_759_449_600)
        let dayTwoDate = Date(timeIntervalSince1970: 1_759_536_000)
        let dayThreeDate = Date(timeIntervalSince1970: 1_759_622_400)
        // Deliberately out of calendar order so index 1 is NOT tomorrow.
        let forecast = [
            AppleWeatherDay(day: "Today Fri 2 Oct", condition: "Clear", highCelsius: 25, lowCelsius: 14, date: dayOneDate, symbolName: "sun.max", precipitationChance: 0.1, windSpeedKPH: 12.5, uvIndex: 6),
            AppleWeatherDay(day: "Sun 5 Oct", condition: "Clouds", highCelsius: 22, lowCelsius: 13, date: dayThreeDate, symbolName: "cloud", precipitationChance: 0.3, windSpeedKPH: 10.0, uvIndex: 4),
            AppleWeatherDay(day: "Tomorrow Sat 3 Oct", condition: "Rain", highCelsius: 20, lowCelsius: 12, date: dayTwoDate, symbolName: "cloud.rain", precipitationChance: 0.8, windSpeedKPH: 20.0, uvIndex: 3)
        ]
        let (weather, _) = preferredDayFixture(forecast: forecast)
        let toolExecutor = makeExecutor(for: weather)
        let result = await toolExecutor.perform(.weather(AppleWeatherRequest(anchor: .currentLocation, kind: .forecast(days: 3), highlightDay: 1)))
        #expect(result?.weatherPresentation?.highlightedDate == dayTwoDate)
        #expect(result?.receipt == nil)
    }

    @Test("A preferred weather day missing from the fetched forecast highlights nothing")
    func preferredWeatherDayMissingFromForecastStaysNil() async {
        let dayOneDate = Date(timeIntervalSince1970: 1_759_449_600)
        let forecast = [
            AppleWeatherDay(day: "Today Fri 2 Oct", condition: "Clear", highCelsius: 25, lowCelsius: 14, date: dayOneDate, symbolName: "sun.max", precipitationChance: 0.1, windSpeedKPH: 12.5, uvIndex: 6)
        ]
        let (weather, _) = preferredDayFixture(forecast: forecast)
        let toolExecutor = makeExecutor(for: weather)
        let result = await toolExecutor.perform(.weather(AppleWeatherRequest(anchor: .currentLocation, kind: .forecast(days: 2), highlightDay: 1)))
        #expect(result?.weatherPresentation?.highlightedDate == nil)
    }

    @Test("A weather highlightDay alone extends the daily forecast to cover it")
    func weatherHighlightDayAloneExtendsForecast() {
        let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil, args: DeviceAgentArguments(highlightDay: 1))
        guard case .request(.weather(let request)) = conversion else {
            Issue.record("expected a weather request")
            return
        }
        #expect(request.kind == .forecast(days: 2))
        #expect(request.highlightDay == 1)
    }

    @Test("A weather highlightDay raises a smaller days argument")
    func weatherHighlightDayRaisesSmallerDays() {
        let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil, args: DeviceAgentArguments(days: 2, highlightDay: 4))
        guard case .request(.weather(let request)) = conversion else {
            Issue.record("expected a weather request")
            return
        }
        #expect(request.kind == .forecast(days: 5))
        #expect(request.highlightDay == 4)
    }

    @Test("Weather hours keep precedence while still carrying the highlight day")
    func weatherHoursKeepPrecedenceWithHighlightDay() {
        let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil, args: DeviceAgentArguments(hours: 6, highlightDay: 1))
        guard case .request(.weather(let request)) = conversion else {
            Issue.record("expected a weather request")
            return
        }
        #expect(request.kind == .hourly(hours: 6))
        #expect(request.highlightDay == 1)
    }

    @Test("An out-of-range weather highlightDay asks instead of requesting")
    func weatherHighlightDayOutOfRangeAsks() {
        for offset in [-1, 5] {
            let conversion = DeviceAgentRequestBuilder.convert(family: "weather", goalID: nil, args: DeviceAgentArguments(highlightDay: offset))
            guard case .askUser(let question) = conversion else {
                Issue.record("expected askUser for highlightDay \(offset)")
                return
            }
            #expect(question == "Which forecast day should I highlight? Choose today or one of the next four days.")
        }
    }
}
