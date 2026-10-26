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
    @Test("A sole independent operation goes directly to arguments across tool families", arguments: DeviceAgentOperationCatalog.all.filter { $0.prerequisites == nil }.map(\.operation))
    func directOperationSelection(operation: AppleToolOperation) {
        let goal = AppleAgentGoal(id: "goal-0", operation: operation, label: "Requested outcome")
        let context = AppleAgentContext(task: "A request", history: [], executed: [], goals: [goal], unfinishedGoals: [goal], remainingSteps: 3, capabilities: [])
        #expect(DeviceAgentStepResolver.directSelection(context) == .execute(operation: operation, family: operation.family, goalID: goal.id))
    }

    @Test func dependentAndMultipleGoalsKeepStepPlanning() {
        let directions = AppleAgentGoal(id: "goal-0", operation: .directions, label: "Directions")
        let time = AppleAgentGoal(id: "goal-1", operation: .currentTime, label: "Time")
        for goals in [[directions], [directions, time]] {
            let context = AppleAgentContext(task: "A request", history: [], executed: [], goals: goals, unfinishedGoals: goals, remainingSteps: 3, capabilities: [])
            #expect(DeviceAgentStepResolver.directSelection(context) == nil)
        }
    }

    @Test func reviewUsesTheSameLocalCalendarAsExecution() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 21))!
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let query = AppleCalendarRangeQuery(start: start, end: end)
        let goal = AppleAgentGoal(id: "goal", operation: .calendarAvailability, label: "Tomorrow")
        let step = AppleAgentExecutedStep(request: .calendarAvailability(query), goalID: goal.id,
            hadResult: true, declined: false, status: .confirmed, summary: "No timed busy blocks", items: [])
        let context = AppleAgentContext(task: "Tomorrow's busy blocks", history: [.init(role: .assistant, text: "The first coffee shop found is Cafe Blue.")], executed: [],
            goals: [goal], unfinishedGoals: [goal], remainingSteps: 3, capabilities: [])
        let prompt = DeviceAgentPlannerPrompts.reviewPrompt(context: context, step: step,
            result: .init(summary: "No timed busy blocks"), now: now, calendar: calendar)
        #expect(prompt.contains("Monday, 26 October 2026"))
        #expect(prompt.contains("27 Oct 2026"))
        #expect(prompt.contains("Europe/Amsterdam"))
        #expect(prompt.contains("Cafe Blue"))
        #expect(!prompt.contains("2026-10-26 23:00:00 +0000"))
    }

}
