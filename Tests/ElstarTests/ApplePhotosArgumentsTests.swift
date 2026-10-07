import Foundation
import Testing
@testable import Elstar

@Suite("Photos arguments")
struct ApplePhotosArgumentsTests {
    @Test func daySearchUsesDeviceTimeZoneAndDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        let query = try ApplePhotosArguments(date: "2026-03-29", screenshotsOnly: true).query(calendar: calendar)
        #expect(try #require(query.end).timeIntervalSince(try #require(query.start)) == 23 * 3600)
        #expect(query.screenshotsOnly)
    }
    @Test func rejectsAmbiguousAndImpossibleDates() throws {
        #expect(throws: AppleToolError.self) { try ApplePhotosArguments(date: "2026-02-30").query() }
        #expect(throws: AppleToolError.self) { try ApplePhotosArguments(startDate: "2026-01-01").query() }
        #expect(throws: AppleToolError.self) { try ApplePhotosArguments(date: "2026-01-01", startDate: "2026-01-01", endDate: "2026-02-01").query() }
    }
    @Test(arguments: [#"{"query":"dogs"}"#, #"{"limit":2.5}"#, #"{"favoritesOnly":"true"}"#, #"{"date":12}"#])
    func rejectsUnsupportedOrMistypedArguments(json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ApplePhotosArguments.self, from: Data(json.utf8)) }
    }
    @Test func sharedPlannerPreservesPhotoFilters() throws {
        let args = DeviceAgentArguments(operation: "find", date: "2026-10-07", albumName: "Holiday", favoritesOnly: true, limit: 4)
        let expected = try ApplePhotosArguments(date: args.date, albumName: "Holiday", favoritesOnly: true, limit: 4).query()
        #expect(DeviceAgentRequestBuilder.convert(family: "photos", goalID: nil, args: args) == .request(.findPhotos(expected)))
    }
}
