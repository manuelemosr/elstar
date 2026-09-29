import Testing
import Foundation
@testable import Elstar

@Suite("Tool executor")
struct AppleToolExecutorTests {

    private func makeJournal() -> AppleToolJournal {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        return AppleToolJournal(fileURL: url)
    }

    private func makeExecutor(
        services: AppleToolServices,
        sink: RecordingEventSink,
        tracker: RecordingTracker,
        confirmations: AppleConfirmationStore,
        journal: AppleToolJournal,
        clock: any AppleClock = FixedAppleClock(Date(timeIntervalSince1970: 0))
    ) -> AppleToolExecutor {
        AppleToolExecutor(
            key: HarnessConversationKey(absoluteKey: "conn/turn"),
            messageID: "m1",
            tracker: tracker,
            sink: sink,
            serializer: AppleOperationSerializer(),
            confirmations: confirmations,
            journal: journal,
            services: services,
            clock: clock
        )
    }

    @Test("A read runs without confirmation, emits running then completed, and records no receipt")
    func readFlow() async {
        let reminders = FakeRemindersService()
        reminders.remindersResult = [
            AppleReminderRecord(id: "r1", title: "Buy milk", due: nil, isCompleted: false)
        ]
        let sink = RecordingEventSink()
        let executor = makeExecutor(
            services: .fake(reminders: reminders),
            sink: sink,
            tracker: RecordingTracker(),
            confirmations: AppleConfirmationStore(),
            journal: makeJournal()
        )

        let result = await executor.perform(.listReminders(listID: nil))
        #expect(result != nil)
        #expect(result?.items.count == 1)
        #expect(result?.receipt == nil)
        #expect(sink.interactions.isEmpty)
        #expect(sink.receipts.isEmpty)
        #expect(sink.deltas.map(\.status) == [.running, .completed])
    }

    @Test("A mutation asks first and is declined without side effects")
    func mutationDeclined() async {
        let places = FakePlacesService()
        let sink = RecordingEventSink()
        let journal = makeJournal()
        let confirmations = AppleConfirmationStore()
        let executor = makeExecutor(
            services: .fake(places: places),
            sink: sink,
            tracker: RecordingTracker(),
            confirmations: confirmations,
            journal: journal
        )

        let request = AppleToolRequest.directions(
            AppleDirectionsRequest(destinationID: "p1", destinationName: "The Park", mode: .walking)
        )
        let task = Task { await executor.perform(request) }
        while confirmations.pendingIDs.isEmpty { await Task.yield() }
        #expect(sink.interactions.count == 1)
        #expect(sink.interactions.first?.options == ["Allow once", "Deny"])
        confirmations.resolve(confirmations.pendingIDs[0], allowed: false)

        let result = await task.value
        #expect(result == nil)
        #expect(places.openedRequests.isEmpty)
        #expect(sink.deltas.map(\.status) == [.running, .failed])
        #expect(await journal.all().isEmpty)
    }

    @Test("An allowed mutation executes once, writes a receipt, and is never replayed in the turn")
    func mutationAllowedAndDeduplicated() async {
        let places = FakePlacesService()
        let sink = RecordingEventSink()
        let journal = makeJournal()
        let confirmations = AppleConfirmationStore()
        let executor = makeExecutor(
            services: .fake(places: places),
            sink: sink,
            tracker: RecordingTracker(),
            confirmations: confirmations,
            journal: journal
        )

        let request = AppleToolRequest.directions(
            AppleDirectionsRequest(destinationID: "p1", destinationName: "The Park", mode: .walking)
        )
        let task = Task { await executor.perform(request) }
        while confirmations.pendingIDs.isEmpty { await Task.yield() }
        confirmations.resolve(confirmations.pendingIDs[0], allowed: true)

        let first = await task.value
        #expect(first != nil)
        #expect(places.openedRequests.count == 1)
        #expect(sink.receipts.count == 1)
        #expect(sink.receipts.first?.status == .confirmed)
        #expect(await journal.all().count == 1)

        // A duplicate call within the same turn returns the cached result
        // without a new confirmation or a second effect.
        let second = await executor.perform(request)
        #expect(second == first)
        #expect(places.openedRequests.count == 1)
        #expect(sink.interactions.count == 1)
    }

    @Test("An unavailable service fails honestly as needing user action")
    func unavailableService() async {
        let sink = RecordingEventSink()
        let executor = makeExecutor(
            services: .unavailable(),
            sink: sink,
            tracker: RecordingTracker(),
            confirmations: AppleConfirmationStore(),
            journal: makeJournal()
        )

        let result = await executor.perform(.weather(AppleWeatherRequest(anchor: .currentLocation, kind: .current)))
        #expect(result?.status == .needsUserAction)
        #expect(result?.summary.contains("isn't available") == true)
        #expect(sink.deltas.last?.status == .failed)
    }

    @Test("Recovery text is actionable for each error class")
    func recoveryText() {
        #expect(AppleToolExecutor.recoveryText(for: .permissionDenied("Reminders")).contains("Action needed"))
        #expect(AppleToolExecutor.recoveryText(for: .uncertain("maybe")).contains("uncertain"))
        #expect(AppleToolExecutor.recoveryText(for: .cancelled).contains("nothing changed"))
    }
}
