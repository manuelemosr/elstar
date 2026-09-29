import Foundation

// MARK: - Plan

/// A required goal the request must satisfy. `id` is stable and assigned by the
/// application (never the model), and `operation` is a concrete operation
/// identity — goals and executions are matched on it, so a same-family but
/// different operation can never discharge a goal.
public nonisolated struct AppleAgentGoal: Equatable, Sendable, Codable {
    public var id: String
    public var operation: AppleToolOperation
    public var label: String

    public var isMutation: Bool { operation.isMutation }

    public init(id: String, operation: AppleToolOperation, label: String) {
        self.id = id
        self.operation = operation
        self.label = label
    }

}

/// The initial structured plan. A conversation streams; an actionable request
/// carries required goals the harness verifies against real results; an
/// actionable request with no valid goals is `invalid` and must not fall back
/// to a permissive "anything happened" check.
public nonisolated enum AppleAgentPlan: Equatable, Sendable {
    case conversation
    case actionable(goals: [AppleAgentGoal])
    case invalid(reason: String)

    public var goals: [AppleAgentGoal] {
        if case .actionable(let goals) = self { return goals }
        return []
    }
}

// MARK: - Prompt budgets

/// Explicit, deterministic prompt budgets used by the real planner/narration
/// path. Full records stay on disk and in the UI; only bounded excerpts reach
/// the model. A clipped reference is never presented as a usable reference.
public nonisolated enum AppleAgentPromptBudget {
    /// Per-step status-line summary budget. Kept small enough that every
    /// executed step's success/uncertain status survives within the aggregate.
    public static let summary = 300
    public static let itemTitle = 120
    public static let itemSubtitle = 120
    /// A reference longer than this is omitted, never clipped into a fake ID.
    public static let itemReference = 300
    public static let receiptDetail = 400
    public static let perStep = 1_200
    public static let aggregateFacts = 4_000
    public static let task = 2_000
    public static let historyTurn = 300
    public static let historyTurns = 6
    public static let label = 120

    public static let truncationMarker = "… [truncated]"
    public static let referenceOmittedMarker = "[reference omitted: too long]"

    public static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + truncationMarker
    }
}

// MARK: - Executed evidence

/// One step the harness actually ran, including the bounded structured content
/// the tool returned (display items with canonical references) and the goal it
/// served, so the next planner step and the final answer can see the real
/// records, not only a count.
public nonisolated struct AppleAgentExecutedStep: Equatable, Sendable {
    public var request: AppleToolRequest
    /// The goal this execution serves. Nil for an auxiliary read, which never
    /// satisfies a required goal.
    public var goalID: String?
    public var hadResult: Bool
    public var declined: Bool
    public var status: AppleToolStatus
    public var summary: String
    public var items: [AppleToolDisplayItem]
    public var receipt: AppleToolReceipt?

    public init(request: AppleToolRequest, goalID: String? = nil, hadResult: Bool, declined: Bool, status: AppleToolStatus, summary: String, items: [AppleToolDisplayItem], receipt: AppleToolReceipt? = nil) {
        self.request = request
        self.goalID = goalID
        self.hadResult = hadResult
        self.declined = declined
        self.status = status
        self.summary = summary
        self.items = items
        self.receipt = receipt
    }

}

// MARK: - Planner seam

/// The bounded context a planner sees when choosing the next step. It contains
/// the current task, the bounded history, the required goals with their
/// satisfaction state, and the real results already gathered — never a place to
/// fabricate a fact.
public nonisolated struct AppleAgentContext: Sendable {
    public var task: String
    public var history: [AppleModelTurn]
    public var executed: [AppleAgentExecutedStep]
    public var goals: [AppleAgentGoal]
    public var unfinishedGoals: [AppleAgentGoal]
    public var remainingSteps: Int
    public var capabilities: [String]

    public init(task: String, history: [AppleModelTurn], executed: [AppleAgentExecutedStep], goals: [AppleAgentGoal], unfinishedGoals: [AppleAgentGoal], remainingSteps: Int, capabilities: [String]) {
        self.task = task
        self.history = history
        self.executed = executed
        self.goals = goals
        self.unfinishedGoals = unfinishedGoals
        self.remainingSteps = remainingSteps
        self.capabilities = capabilities
    }

}

/// A typed next step. The planner may not produce free-form prose as a step:
/// either it executes a validated request for a declared goal, asks the person
/// for required missing information, or finishes. An execution that names no
/// goal is auxiliary and can never satisfy a required goal; a mutating
/// execution must name a declared goal.
public nonisolated enum AppleAgentStep: Equatable, Sendable {
    case execute(AppleToolRequest, goalID: String?)
    case askUser(String)
    case finish
}

/// Drives the plan-act-verify loop. Implementations must not fabricate facts;
/// they choose among real tool operations and bounded questions.
public nonisolated protocol AppleAgentPlanner: Sendable {
    /// The initial structured plan for the request.
    func plan(task: String, history: [AppleModelTurn]) async throws -> AppleAgentPlan
    func nextStep(_ context: AppleAgentContext) async throws -> AppleAgentStep
    /// Bounded reconsideration used when a conversation-classified follow-up may
    /// actually be confirming or supplying details for a pending action. It is a
    /// protocol requirement so a real planner's stronger prompt is dispatched
    /// through the existential; the default is a plain replan. It never
    /// hard-codes English keyword routing and performs no device work.
    func reconsider(task: String, history: [AppleModelTurn], pendingAction: Bool) async throws -> AppleAgentPlan
}

nonisolated extension AppleAgentPlanner {
    public func reconsider(task: String, history: [AppleModelTurn], pendingAction: Bool) async throws -> AppleAgentPlan {
        try await plan(task: task, history: history)
    }
}

// MARK: - Outcome

public nonisolated struct AppleAgentOutcome: Equatable, Sendable {
    public nonisolated enum Ending: Equatable, Sendable {
        /// Every required goal was satisfied; a grounded narration may stream.
        case answered
        /// A required piece of information is missing.
        case askedUser(String)
        /// Some goals were met but others were not, within the bounded budget.
        case partial(String)
        /// The request could not be completed within the bounded budget.
        case unresolved(String)
        /// The person declined a mutating action.
        case declined
        /// The planner failed or the capability is unavailable.
        case unavailable(String)
    }

    public var ending: Ending
    public var executed: [AppleAgentExecutedStep]
    /// Compact, model-facing recap of what actually happened. Authoritative.
    public var groundedFacts: String

    public init(ending: Ending, executed: [AppleAgentExecutedStep], groundedFacts: String) {
        self.ending = ending
        self.executed = executed
        self.groundedFacts = groundedFacts
    }
}

// MARK: - Harness

/// Bounded executor-controlled action harness. It refuses a premature finish
/// until every required goal is backed by its own successful real read or its
/// own *confirmed* matching write receipt, deduplicates possibly-committed
/// writes per goal+request so no goal is written twice, and produces an honest
/// partial/unresolved result when the budget runs out instead of inventing
/// success.
public nonisolated final class AppleAgentHarness: @unchecked Sendable {
    public let planner: any AppleAgentPlanner
    public let dispatcher: any AppleToolDispatching
    public let maxSteps: Int
    public let maxReadRecovery: Int
    public let capabilities: [String]

    public init(
        planner: any AppleAgentPlanner,
        dispatcher: any AppleToolDispatching,
        maxSteps: Int = 8,
        maxReadRecovery: Int = 2,
        capabilities: [String] = AppleAgentHarness.defaultCapabilities
    ) {
        self.planner = planner
        self.dispatcher = dispatcher
        self.maxSteps = maxSteps
        self.maxReadRecovery = maxReadRecovery
        self.capabilities = capabilities
    }

    public static let defaultCapabilities = [
        "current time (device clock)",
        "reminders: list",
        "calendar: list/availability",
        "places: search, current location, directions",
        "weather",
        "read one public web page",
    ]

    /// Strictly maps raw planner goal descriptions to a plan. Any unknown
    /// operation, or an actionable plan with no valid goals, is `invalid` so the
    /// caller can replan/ask honestly instead of executing unrelated actions.
    public static func plan(goals raw: [(operation: String, label: String)]) -> AppleAgentPlan {
        guard !raw.isEmpty else { return .invalid(reason: "No concrete operation was planned.") }
        var goals: [AppleAgentGoal] = []
        for (index, item) in raw.enumerated() {
            guard let goal = makeGoal(index: index, operation: item.operation, label: item.label) else {
                return .invalid(reason: "The plan named an operation I can't perform: \(AppleAgentPromptBudget.clip(item.operation, to: 60)).")
            }
            goals.append(goal)
        }
        return .actionable(goals: goals)
    }

    public static func makeGoal(index: Int, operation: String, label: String) -> AppleAgentGoal? {
        let trimmedOperation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let operation = AppleToolOperation(rawValue: trimmedOperation) else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleAgentGoal(
            id: "goal-\(index)",
            operation: operation,
            label: trimmedLabel.isEmpty ? operation.displayName : AppleAgentPromptBudget.clip(trimmedLabel, to: AppleAgentPromptBudget.label)
        )
    }

    public func run(task: String, history: [AppleModelTurn], goals: [AppleAgentGoal]) async -> AppleAgentOutcome {
        // A plan must carry unique, non-empty goal IDs. This is app-assigned and
        // never sourced from the model, so a model cannot invent goals to bypass
        // the loop bounds.
        let goalIDs = Set(goals.map(\.id))
        guard !goals.isEmpty, goalIDs.count == goals.count else {
            return AppleAgentOutcome(
                ending: .partial("I couldn't line up a safe plan for that request."),
                executed: [],
                groundedFacts: ""
            )
        }

        var executed: [AppleAgentExecutedStep] = []
        var readRecovery = 0
        var duplicateRepeats = 0
        var invalidAttempts = 0
        var satisfiedGoalRepeats = 0
        var plannerCalls = 0
        var stickyKeys: Set<String> = []
        var ending: AppleAgentOutcome.Ending?

        while plannerCalls < maxSteps, ending == nil {
            // A cancelled generation must stop before spending another model
            // inference on a planner step the caller no longer wants.
            if Task.isCancelled {
                ending = .unavailable("The request was stopped.")
                break
            }
            // Deterministic completion: once every required goal is backed by
            // its own successful confirmed evidence, the turn is answered
            // without another planner call. A model that keeps re-issuing a
            // satisfied single read (or write) therefore cannot multiply
            // inferences; the completion does not rely on the model's finish.
            if Self.allSatisfied(goals, in: executed) {
                ending = .answered
                break
            }
            plannerCalls += 1
            let context = AppleAgentContext(
                task: task,
                history: history,
                executed: executed,
                goals: goals,
                unfinishedGoals: Self.unfinished(goals, in: executed),
                remainingSteps: maxSteps - plannerCalls,
                capabilities: capabilities
            )
            let step: AppleAgentStep
            do {
                step = try await planner.nextStep(context)
            } catch {
                ending = .unavailable(error.localizedDescription)
                break
            }

            switch step {
            case .execute(let request, let goalID):
                if let goalID {
                    guard let goal = goals.first(where: { $0.id == goalID }), goal.operation == request.operation else {
                        invalidAttempts += 1
                        if invalidAttempts > maxReadRecovery {
                            ending = .partial(Self.partialMessage(goals: goals, executed: executed))
                            break
                        }
                        continue
                    }
                    // While other goals remain unfinished, an execute that
                    // names a goal already backed by its own confirmed evidence
                    // is rejected without dispatching another read or write.
                    // The planner gets a bounded chance to replan for a
                    // genuinely outstanding goal; genuinely distinct goals and
                    // auxiliary reads are unaffected.
                    if Self.satisfied(goal, in: executed) {
                        satisfiedGoalRepeats += 1
                        if satisfiedGoalRepeats > maxReadRecovery {
                            ending = .partial(Self.partialMessage(goals: goals, executed: executed))
                            break
                        }
                        continue
                    }
                } else if request.isMutation {
                    // A write with no declared goal is not allowed.
                    invalidAttempts += 1
                    if invalidAttempts > maxReadRecovery {
                        ending = .partial(Self.partialMessage(goals: goals, executed: executed))
                        break
                    }
                    continue
                }

                // Idempotency is scoped to goal+request so a planner retry of one
                // goal never writes twice, while genuinely distinct goals each run.
                let stickyKey = "\(goalID ?? "aux")|\(request.signature)"
                if request.isMutation, stickyKeys.contains(stickyKey) {
                    duplicateRepeats += 1
                    if duplicateRepeats > maxReadRecovery {
                        ending = .unresolved("I already tried that action and will not repeat it automatically.\n\(Self.facts(executed))")
                        break
                    }
                    continue
                }
                if request.isMutation { stickyKeys.insert(stickyKey) }

                let result = await dispatcher.perform(request)
                if let result {
                    executed.append(AppleAgentExecutedStep(
                        request: request,
                        goalID: goalID,
                        hadResult: true,
                        declined: false,
                        status: result.status,
                        summary: result.summary,
                        items: result.items,
                        receipt: result.receipt
                    ))
                } else {
                    // A nil result means the person declined; reads are never
                    // confirmed, so this only happens for a mutation.
                    executed.append(AppleAgentExecutedStep(
                        request: request,
                        goalID: goalID,
                        hadResult: false,
                        declined: true,
                        status: .failed,
                        summary: "The person declined this action.",
                        items: [],
                        receipt: nil
                    ))
                    ending = .declined
                    break
                }

            case .askUser(let question):
                ending = .askedUser(question)
                break

            case .finish:
                if Self.allSatisfied(goals, in: executed) {
                    ending = .answered
                    break
                }
                if readRecovery < maxReadRecovery {
                    readRecovery += 1
                } else {
                    ending = .partial(Self.partialMessage(goals: goals, executed: executed))
                    break
                }
            }
        }

        if ending == nil {
            ending = Self.allSatisfied(goals, in: executed)
                ? .answered
                : .partial(Self.partialMessage(goals: goals, executed: executed))
        }

        return AppleAgentOutcome(ending: ending!, executed: executed, groundedFacts: Self.facts(executed))
    }

    // MARK: - Goal satisfaction

    /// A goal is satisfied only by an execution that names THIS goal id and is
    /// successful: a `confirmed` non-mutation read, or a `confirmed` mutating
    /// receipt. One execution names one goal, so one receipt can never discharge
    /// two goals.
    public static func satisfied(_ goal: AppleAgentGoal, in executed: [AppleAgentExecutedStep]) -> Bool {
        executed.contains { step in
            step.goalID == goal.id && isSuccessful(step)
        }
    }

    public static func isSuccessful(_ step: AppleAgentExecutedStep) -> Bool {
        guard step.hadResult, !step.declined else { return false }
        if step.request.isMutation { return step.receipt?.status == .confirmed }
        return step.status == .confirmed
    }

    public static func unfinished(_ goals: [AppleAgentGoal], in executed: [AppleAgentExecutedStep]) -> [AppleAgentGoal] {
        goals.filter { !satisfied($0, in: executed) }
    }

    public static func allSatisfied(_ goals: [AppleAgentGoal], in executed: [AppleAgentExecutedStep]) -> Bool {
        !goals.isEmpty && goals.allSatisfy { satisfied($0, in: executed) }
    }

    public static func partialMessage(goals: [AppleAgentGoal], executed: [AppleAgentExecutedStep]) -> String {
        let remaining = unfinished(goals, in: executed)
        if remaining.isEmpty {
            return "I couldn't complete that within a few steps."
        }
        let labels = remaining.map(\.label).joined(separator: ", ")
        return "I couldn't finish everything you asked. Still outstanding: \(labels)."
    }

    // MARK: - Bounded facts

    /// Authoritative, deterministically bounded recap of executed steps. Every
    /// step's success/uncertain status and summary survive; item/receipt details
    /// are included within the budget, and any overflow is marked honestly. Read
    /// content is untrusted data, carried as data only.
    public static func facts(_ executed: [AppleAgentExecutedStep]) -> String {
        guard !executed.isEmpty else { return "" }

        // Pass 1: status lines for every step (bounded each), so success state
        // and goal evidence are never lost to detail overflow. The per-status
        // budget is small enough that every step's status fits within the
        // aggregate even at the maximum step count.
        let statusLines = executed.map { step -> String in
            if step.declined { return "- \(step.request.toolName): declined by the person" }
            return "- \(step.request.toolName) [\(step.status.rawValue)]: \(AppleAgentPromptBudget.clip(step.summary, to: AppleAgentPromptBudget.summary))"
        }
        let statusTotal = statusLines.reduce(0) { $0 + $1.count + 1 }
        var detailBudget = max(0, AppleAgentPromptBudget.aggregateFacts - statusTotal)

        // Pass 2: append bounded details while the aggregate allows.
        var blocks: [String] = []
        for (index, step) in executed.enumerated() {
            var block = statusLines[index]
            if !step.declined, detailBudget > 0 {
                let details = boundedDetails(for: step, budget: min(AppleAgentPromptBudget.perStep, detailBudget))
                if !details.isEmpty {
                    block += details
                    detailBudget -= details.count
                }
            }
            blocks.append(block)
            if detailBudget <= 0 { continue }
        }
        return blocks.joined(separator: "\n")
    }

    private static func boundedDetails(for step: AppleAgentExecutedStep, budget: Int) -> String {
        var remaining = budget
        var text = ""
        for item in step.items.prefix(12) {
            var line = "\n    - \(AppleAgentPromptBudget.clip(item.title, to: AppleAgentPromptBudget.itemTitle))"
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                line += " (\(AppleAgentPromptBudget.clip(subtitle, to: AppleAgentPromptBudget.itemSubtitle)))"
            }
            if let reference = item.reference, !reference.isEmpty {
                if reference.count <= AppleAgentPromptBudget.itemReference {
                    line += " [ref \(reference)]"
                } else {
                    // Never present a clipped id as a usable reference.
                    line += " \(AppleAgentPromptBudget.referenceOmittedMarker)"
                }
            }
            if line.count > remaining { break }
            text += line
            remaining -= line.count
        }
        if let detail = step.receipt?.detail {
            let clipped = AppleAgentPromptBudget.clip(detail.replacingOccurrences(of: "\n", with: "; "), to: AppleAgentPromptBudget.receiptDetail)
            let line = "\n    receipt: \(clipped)"
            if line.count <= remaining { text += line }
        }
        return text
    }
}