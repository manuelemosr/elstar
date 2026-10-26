import Foundation
import Testing
@testable import Elstar

@Suite("Planner location and forecast defaults")
struct DevicePlannerDefaultsTests {
    @Test func advertisedDateExampleUsesCurrentLocationAndResolvesWeekday() throws {
        let contract = try #require(DeviceAgentOperationCatalog.all.first { $0.operation == .weather })
        let args = try JSONDecoder().decode(DeviceAgentArguments.self, from: Data(contract.exampleJSON.utf8))
        let selection = DeviceAgentStepSelection.execute(operation: .weather, family: .weather, goalID: "forecast")
        // Wednesday Oct 21, 2026 -> Saturday = offset 3, needs 4 days
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let wednesday = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 11, minute: 47))!
        let conversion = DeviceAgentRequestBuilder.convertSelected(selection: selection, args: args,
            clock: FixedAppleClock(wednesday), calendar: cal)
        guard case .success(.request(.weather(let request))) = conversion else { Issue.record("Expected weather request"); return }
        #expect(request.anchor == .currentLocation)
        #expect(request.highlightDay == 3)
        guard case .forecast(let days) = request.kind else { Issue.record("Expected forecast"); return }
        #expect(days == 4)
    }

    @Test func onlyUnfinishedGoalsAreOfferedForExecution() {
        let complete = AppleAgentGoal(id: "finished-weather", operation: .weather, label: "Tomorrow's weather")
        let outstanding = AppleAgentGoal(id: "remaining-sushi", operation: .searchNearbyPlaces, label: "Sushi")
        let context = AppleAgentContext(task: "Weather and sushi", history: [], executed: [], goals: [complete, outstanding],
            unfinishedGoals: [outstanding], remainingSteps: 4, capabilities: [])
        let instructions = DeviceAgentPlannerPrompts.stepInstructions(context: context, now: Date(), calendar: Calendar(identifier: .gregorian))
        let choices = instructions.components(separatedBy: "Executable outstanding goals").last?.components(separatedBy: "Completed goals").first ?? ""
        #expect(choices.contains("remaining-sushi"))
        #expect(!choices.contains("finished-weather"))
        #expect(instructions.contains("finished-weather: already completed"))
    }
}
