import Foundation
import Testing

@testable import Elstar

/// The on-device model gate must be conservative: every 8 GB Apple
/// Intelligence iPhone (15 Pro/Max, 16, 16 Plus, 16e, 17, 17e) is below
/// the 12 GiB floor, and every 12 GB device (16 Pro/Max, 17 Pro/Max,
/// Air, 18 Pro/Pro Max, Duo) is at or above it.
struct AppleIntelligenceModelHostTests {
    private enum Cases {
        static let gib: UInt64 = 1024 * 1024 * 1024
        static let all: [(UInt64, Bool)] = [
            (0, false),
            (8 * gib, false),
            (11 * gib + gib / 2, false),
            (12 * gib, true),
            (16 * gib, true),
        ]
    }

    @Test(arguments: Cases.all)
    func gatesOnTheTwelveGigabyteFloor(_ bytes: UInt64, _ expected: Bool) {
        #expect(AppleIntelligenceModelHost.hasSufficientMemory(bytes) == expected)
    }

    @Test func floorIsTwelveGibibytes() {
        #expect(AppleIntelligenceModelHost.minimumMemoryBytes == 12 * 1024 * 1024 * 1024)
    }
}
