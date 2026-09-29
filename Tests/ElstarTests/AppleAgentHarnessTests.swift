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
}

private final class FailingPlanner: AppleAgentPlanner, @unchecked Sendable {
    struct Failure: Error {}
    func plan(task: String, history: [AppleModelTurn]) async throws -> AppleAgentPlan { .conversation }
    func nextStep(_ context: AppleAgentContext) async throws -> AppleAgentStep { throw Failure() }
}
