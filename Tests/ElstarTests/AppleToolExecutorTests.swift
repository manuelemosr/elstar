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

    @Test("Directions prepares a presentation with no confirmation, receipt, or side effect")
    func directionsPreparesPresentation() async {
        let sink = RecordingEventSink()
        let journal = makeJournal()
        let confirmations = AppleConfirmationStore()
        let executor = makeExecutor(
            services: .fake(),
            sink: sink,
            tracker: RecordingTracker(),
            confirmations: confirmations,
            journal: journal
        )

        let request = AppleToolRequest.directions(
            AppleDirectionsRequest(destinationID: "p1", destinationName: "The Park", destinationAddress: "1 Park Rd", mode: .walking)
        )
        let result = await executor.perform(request)

        #expect(result?.directionsPresentation?.destinationName == "The Park")
        #expect(result?.directionsPresentation?.mode == .walking)
        #expect(result?.receipt == nil)
        #expect(sink.interactions.isEmpty)
        #expect(sink.receipts.isEmpty)
        #expect(sink.deltas.map(\.status) == [.running, .completed])
        #expect(await journal.all().isEmpty)
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
