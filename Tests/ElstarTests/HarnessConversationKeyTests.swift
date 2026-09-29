import Testing
import Elstar

@Suite
struct HarnessConversationKeyTests {
    @Test func conversationIDTakesTheComponentAfterTheConnectionSeparator() {
        let key = HarnessConversationKey(absoluteKey: "connection-id/conversation-id")
        #expect(key.conversationID == "conversation-id")
        #expect(key.absoluteKey == "connection-id/conversation-id")
    }

    @Test func conversationIDFallsBackToTheWholeKeyWhenThereIsNoSeparator() {
        let key = HarnessConversationKey(absoluteKey: "plain-key")
        #expect(key.conversationID == "plain-key")
    }
}
