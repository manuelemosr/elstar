import Testing
import Foundation
@testable import Elstar

@Suite("Tool domain")
struct AppleToolDomainTests {

    @Test("The catalog has exactly the supported families and no removed ones")
    func catalogFamilies() {
        #expect(Set(AppleToolFamily.allCases) == [.reminders, .calendar, .places, .weather, .webfetch, .time])
    }

    @Test("Only opening Maps directions is a mutation")
    func mutationSet() {
        let mutations = AppleToolOperation.allCases.filter(\.isMutation)
        #expect(mutations == [.directions])
    }

    @Test("Every operation has a unique stable raw value and a display name")
    func operationIdentity() {
        let rawValues = AppleToolOperation.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
        #expect(AppleToolOperation.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(AppleToolOperation.allCases.allSatisfy { AppleToolFamily.allCases.contains($0.family) })
    }

    @Test("Request family and operation map back to their concrete identity")
    func requestIdentity() {
        let requests: [AppleToolRequest] = [
            .currentTime,
            .listReminderLists,
            .listReminders(listID: "home"),
            .listCalendarEvents(AppleCalendarRangeQuery(start: .init(), end: .init())),
            .calendarAvailability(AppleCalendarRangeQuery(start: .init(), end: .init())),
            .searchNearbyPlaces(AppleNearbyPlacesRequest(query: "coffee", anchor: .currentLocation, limit: 5)),
            .currentPlace(AppleCurrentPlaceRequest()),
            .directions(AppleDirectionsRequest(destinationID: "p1", destinationName: "Blue Bottle", mode: .walking)),
            .weather(AppleWeatherRequest(anchor: .currentLocation, kind: .current)),
            .fetchWebPage(AppleFetchWebPageRequest(url: URL(string: "https://example.com")!))
        ]
        for request in requests {
            #expect(request.operation.family == request.family)
        }
        #expect(requests.count == AppleToolOperation.allCases.count)
    }

    @Test("Directions is the only operation requiring confirmation")
    func confirmation() {
        let directions = AppleToolRequest.directions(
            AppleDirectionsRequest(destinationID: "p1", destinationName: "The Park", mode: .walking)
        )
        #expect(directions.isMutation)
        #expect(directions.confirmationTitle == "Open Maps for directions?")
        #expect(directions.confirmationDetail == "Open Maps to \"The Park\" - walking.")
        #expect(!AppleToolRequest.currentTime.isMutation)
        #expect(AppleToolRequest.currentTime.confirmationDetail == nil)
    }

    @Test("Error copy is honest and never a silent success")
    func errorCopy() {
        #expect(AppleToolError.permissionDenied("Reminders").userMessage.contains("denied"))
        #expect(AppleToolError.notAvailable("Weather isn't available on this platform.").userMessage.contains("available"))
        #expect(AppleToolError.cancelled.userMessage.contains("cancelled"))
    }
}
