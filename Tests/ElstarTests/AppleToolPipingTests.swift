import Testing
import Foundation
@testable import Elstar

@Suite("Piping: flag, confirmations, serializer, journal")
struct AppleToolPipingTests {

    @Test("AppleOnceFlag claims exactly once")
    func onceFlag() {
        let flag = AppleOnceFlag()
        #expect(flag.claim())
        #expect(!flag.claim())
        #expect(!flag.claim())
    }

    @Test("ConfirmationStore resumes the pending continuation with the decision")
    func confirmationStore() async {
        let store = AppleConfirmationStore()
        async let allowed = withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            store.insert("a", c)
        }
        while store.pendingIDs.isEmpty { await Task.yield() }
        #expect(store.pendingIDs == ["a"])
        store.resolve("a", allowed: true)
        #expect(await allowed)
        #expect(store.pendingIDs.isEmpty)
    }

    @Test("cancelAll declines every pending request and is idempotent")
    func cancelAll() async {
        let store = AppleConfirmationStore()
        async let first = withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in store.insert("a", c) }
        async let second = withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in store.insert("b", c) }
        while store.pendingIDs.count < 2 { await Task.yield() }
        store.cancelAll()
        #expect(await first == false)
        #expect(await second == false)
        store.cancelAll()
        #expect(store.pendingIDs.isEmpty)
    }

    @Test("Serializer admits one operation at a time")
    func serializerSerializes() async {
        let serializer = AppleOperationSerializer()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await serializer.run {
                        await counter.enter()
                    }
                }
            }
        }
        #expect(await counter.maxConcurrent == 1)
    }

    @Test("Journal persists receipts, scopes summaries to a conversation, and reloads")
    func journalPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let journal = AppleToolJournal(fileURL: url)
        let confirmed = AppleToolReceipt(operationID: "op1", family: .places, action: "Open directions", nativeID: "p1", summary: "Opened Maps to \"Park\".", recordedAt: Date(timeIntervalSince1970: 0), status: .confirmed, conversationID: "chat-1")
        let uncertain = AppleToolReceipt(operationID: "op2", family: .places, action: "Open directions", nativeID: nil, summary: "maybe", recordedAt: Date(timeIntervalSince1970: 1), status: .uncertain, conversationID: "chat-1")
        let otherChat = AppleToolReceipt(operationID: "op3", family: .places, action: "Open directions", nativeID: nil, summary: "other", recordedAt: Date(timeIntervalSince1970: 2), status: .confirmed, conversationID: "chat-2")

        await journal.record(confirmed)
        await journal.record(uncertain)
        await journal.record(otherChat)
        #expect(await journal.all().count == 3)

        let reloaded = AppleToolJournal(fileURL: url)
        let receipts = await reloaded.all()
        #expect(receipts.count == 3)
        #expect(receipts.first?.status == .confirmed)

        let committed = await reloaded.committedSummary(conversationID: "chat-1")
        #expect(committed?.contains("verified") == true)
        #expect(committed?.contains("maybe") == false)

        let attention = await reloaded.attentionSummary(conversationID: "chat-1")
        #expect(attention?.contains("uncertain") == true)
        #expect(await reloaded.attentionSummary(conversationID: "chat-9") == nil)
    }
}

private actor Counter {
    private(set) var maxConcurrent = 0
    private var current = 0

    func enter() async {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
        try? await Task.sleep(nanoseconds: 2_000_000)
        current -= 1
    }
}
