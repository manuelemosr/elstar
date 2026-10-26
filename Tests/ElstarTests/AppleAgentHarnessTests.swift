import Testing
import Foundation
@testable import Elstar

@Suite("Plan-act-verify harness")
struct AppleAgentHarnessTests {

    @Test("Strict plan mapping rejects empty and unknown operations")
    func planMapping() {
        if case .invalid = AppleAgentHarness.plan(goals: []) {
            // expected
        } else {
            Issue.record("An empty plan should be invalid")
        }

        if case .invalid = AppleAgentHarness.plan(goals: [("not.an.operation", "x")]) {
            // expected
        } else {
            Issue.record("An unknown operation should be invalid")
        }

        let plan = AppleAgentHarness.plan(goals: [("reminders.list", "list reminders")])
        #expect(plan == .actionable(goals: [AppleAgentGoal(id: "goal-0", operation: .listReminders, label: "list reminders")]))
    }

    @Test("A confirmed read discharges its goal and answers")
    func satisfiedRead() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .listReminders, label: "list")
        let planner = ScriptedPlanner(
            plan: .actionable(goals: [goal]),
            steps: [.execute(.listReminders(listID: nil), goalID: "goal-0")]
        )
        let dispatcher = FakeDispatcher()
        dispatcher.result = AppleToolResult(summary: "Found 1 reminder.", items: [AppleToolDisplayItem(title: "Buy milk")])

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher)
        let outcome = await harness.run(task: "list my reminders", history: [], goals: [goal])

        #expect(outcome.ending == .answered)
        #expect(dispatcher.performed.count == 1)
        #expect(outcome.groundedFacts.contains("Buy milk"))
    }

    @Test("A declined mutation ends declined and never satisfies the goal")
    func declinedMutation() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .directions, label: "directions")
        let request = AppleToolRequest.directions(AppleDirectionsRequest(destinationID: "p1", destinationName: "Park", mode: .walking))
        let planner = ScriptedPlanner(plan: .actionable(goals: [goal]), steps: [.execute(request, goalID: "goal-0")])
        let dispatcher = FakeDispatcher()
        dispatcher.returnsNil = true

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher)
        let outcome = await harness.run(task: "directions to the park", history: [], goals: [goal])

        #expect(outcome.ending == .declined)
        #expect(outcome.executed.first?.declined == true)
    }

    @Test("A failing planner is reported as unavailable, not as success")
    func plannerFailure() async {
        let failing = FailingPlanner()
        let harness = AppleAgentHarness(planner: failing, dispatcher: FakeDispatcher())
        let goal = AppleAgentGoal(id: "goal-0", operation: .listReminders, label: "list")
        let outcome = await harness.run(task: "list", history: [], goals: [goal])
        if case .unavailable = outcome.ending {
            // expected
        } else {
            Issue.record("A planner error should end unavailable, got \(outcome.ending)")
        }
    }

    @Test("A failed read does not satisfy its goal")
    func failedReadDoesNotSatisfy() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .listReminders, label: "list")
        let planner = ScriptedPlanner(plan: .actionable(goals: [goal]), steps: [.execute(.listReminders(listID: nil), goalID: "goal-0")])
        let dispatcher = FakeDispatcher()
        dispatcher.result = AppleToolResult(summary: "Denied.", status: .needsUserAction)

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher)
        let outcome = await harness.run(task: "list", history: [], goals: [goal])

        #expect(outcome.ending != .answered)
    }

    // MARK: - Result review

    @Test("A rejected result does not satisfy the goal and the planner can retry")
    func rejectedResultAllowsRetry() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .weather, label: "weather for Saturday")
        let request = AppleToolRequest.weather(AppleWeatherRequest(anchor: .currentLocation, kind: .forecast(days: 2), highlightDay: 1))
        // First attempt: wrong day (tomorrow). Review rejects. Second attempt: correct.
        let planner = ScriptedPlanner(
            plan: .actionable(goals: [goal]),
            steps: [
                .execute(request, goalID: "goal-0"),
                .execute(request, goalID: "goal-0"),
            ],
            reviews: [
                .rejected(reason: "The user asked for Saturday but the result shows Thursday's weather."),
                .approved,
            ]
        )
        let dispatcher = FakeDispatcher()
        dispatcher.result = AppleToolResult(summary: "Thursday: Cloudy, 18C", items: [])

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher)
        let outcome = await harness.run(task: "what's the weather for Saturday?", history: [], goals: [goal])

        #expect(outcome.ending == .answered)
        #expect(dispatcher.performed.count == 2)
        #expect(outcome.executed.count == 2)
        #expect(outcome.executed[0].reviewRejected == true)
        #expect(outcome.executed[0].reviewReason?.contains("Saturday") == true)
        #expect(outcome.executed[1].reviewRejected == false)
    }

    @Test("Repeated rejected results never become accepted when retries run out")
    func maxRetriesDoesNotAcceptRejectedResult() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .weather, label: "weather")
        let request = AppleToolRequest.weather(AppleWeatherRequest(anchor: .currentLocation, kind: .current))
        // The fourth selection cannot dispatch after three rejected results.
        let planner = ScriptedPlanner(
            plan: .actionable(goals: [goal]),
            steps: [
                .execute(request, goalID: "goal-0"),
                .execute(request, goalID: "goal-0"),
                .execute(request, goalID: "goal-0"),
                .execute(request, goalID: "goal-0"),
            ],
            reviews: [
                .rejected(reason: "wrong day"),
                .rejected(reason: "wrong day"),
                .rejected(reason: "wrong day"),
            ]
        )
        let dispatcher = FakeDispatcher()
        dispatcher.result = AppleToolResult(summary: "Today: Sunny, 21C", items: [])

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher, maxRetriesPerGoal: 3)
        let outcome = await harness.run(task: "weather", history: [], goals: [goal])

        #expect(outcome.ending != .answered)
        #expect(dispatcher.performed.count == 3)
        #expect(outcome.executed.filter(\.reviewRejected).count == 3)
        #expect(!AppleAgentHarness.satisfied(goal, in: outcome.executed))
    }

    @Test("A review failure leaves the goal unverified")
    func reviewFailureDoesNotAcceptResult() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .listReminders, label: "list")
        let planner = ScriptedPlanner(
            plan: .actionable(goals: [goal]),
            steps: [.execute(.listReminders(listID: nil), goalID: "goal-0"), .execute(.listReminders(listID: nil), goalID: "goal-0")],
            reviews: []
        )
        planner.reviewFails = true
        let dispatcher = FakeDispatcher()
        dispatcher.result = AppleToolResult(summary: "Found 1 reminder.", items: [AppleToolDisplayItem(title: "Buy milk")])

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher)
        let outcome = await harness.run(task: "list my reminders", history: [], goals: [goal])

        #expect(outcome.ending != .answered)
        #expect(outcome.executed[0].reviewRejected)
        #expect(dispatcher.performed.count == 1)
        guard case .unavailable = outcome.ending else { Issue.record("An unavailable reviewer must stop without replaying tools"); return }
    }

    @Test("Final reporting excludes rejected and failed records across tool families")
    func answerFactsExcludeUnverifiedAttempts() {
        let rejected = AppleAgentExecutedStep(request: .listReminders(listID: nil), goalID: "g", hadResult: true,
            declined: false, status: .confirmed, summary: "Wrong list", items: [], reviewRejected: true, reviewReason: "Wrong list")
        let failed = AppleAgentExecutedStep(request: .currentTime, goalID: nil, hadResult: true,
            declined: false, status: .failed, summary: "Clock failed", items: [])
        let approved = AppleAgentExecutedStep(request: .listReminders(listID: nil), goalID: "g", hadResult: true,
            declined: false, status: .confirmed, summary: "Correct reminders", items: [])
        let facts = AppleAgentHarness.answerFacts([rejected, failed, approved])
        #expect(facts.contains("Correct reminders"))
        #expect(!facts.contains("Wrong list"))
        #expect(!facts.contains("Clock failed"))
        #expect(!facts.contains("rejected"))
    }

    @Test("Rejected steps appear in grounded facts with the rejection reason")
    func rejectedStepsInFacts() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .weather, label: "weather for Saturday")
        let request = AppleToolRequest.weather(AppleWeatherRequest(anchor: .currentLocation, kind: .forecast(days: 2), highlightDay: 1))
        let planner = ScriptedPlanner(
            plan: .actionable(goals: [goal]),
            steps: [
                .execute(request, goalID: "goal-0"),
                .execute(request, goalID: "goal-0"),
            ],
            reviews: [
                .rejected(reason: "Wrong day: got Thursday, user asked for Saturday."),
                .approved,
            ]
        )
        let dispatcher = FakeDispatcher()
        dispatcher.result = AppleToolResult(summary: "Thursday: Cloudy", items: [])

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher)
        let outcome = await harness.run(task: "what's the weather for Saturday?", history: [], goals: [goal])

        #expect(outcome.groundedFacts.contains("rejected"))
        #expect(outcome.groundedFacts.contains("Wrong day"))
    }

    @Test("Auxiliary reads are not reviewed")
    func auxiliaryReadsNotReviewed() async {
        let goal = AppleAgentGoal(id: "goal-0", operation: .listReminders, label: "list")
        // First step: auxiliary read (no goalID). Second step: goal-bound execute.
        let planner = ScriptedPlanner(
            plan: .actionable(goals: [goal]),
            steps: [
                .execute(.currentTime, goalID: nil),
                .execute(.listReminders(listID: nil), goalID: "goal-0"),
            ],
            reviews: [.approved] // Only one review, for the goal-bound step
        )
        let dispatcher = FakeDispatcher()
        dispatcher.result = AppleToolResult(summary: "Done.", items: [])

        let harness = AppleAgentHarness(planner: planner, dispatcher: dispatcher)
        let outcome = await harness.run(task: "list", history: [], goals: [goal])

        // The auxiliary read (currentTime) should not be reviewed.
        #expect(outcome.executed[0].goalID == nil)
        #expect(outcome.executed[0].reviewRejected == false)
        #expect(outcome.executed[1].goalID == "goal-0")
    }
}

private final class FailingPlanner: AppleAgentPlanner, @unchecked Sendable {
    struct Failure: Error {}
    func plan(task: String, history: [AppleModelTurn]) async throws -> AppleAgentPlan { .conversation }
    func nextStep(_ context: AppleAgentContext) async throws -> AppleAgentStep { throw Failure() }
}
