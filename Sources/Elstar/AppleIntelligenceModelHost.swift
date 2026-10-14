import Foundation

/// Pure device-capability gate for Localzie's on-device model.
///
/// Localzie's Apple Intelligence connection uses the advanced on-device
/// variant of Apple's foundation model (AFM 3 Core Advanced: 20 billion
/// parameters, sparse, stored in flash). Apple documents its floor as an
/// A19 Pro-class chip with at least 12 GiB of physical memory. The chip
/// verdict is delegated to the operating system's own model-availability
/// answer (the app target reads it from the FoundationModels framework),
/// so only the memory floor lives here, where it stays testable without
/// any Apple framework.
public enum AppleIntelligenceModelHost {
    /// Apple's documented floor for the advanced on-device model:
    /// at least 12 GiB of physical memory.
    public static let minimumMemoryBytes: UInt64 = 12 * 1024 * 1024 * 1024

    /// Conservative physical-memory check. A device below the floor is
    /// never offered the on-device model, whatever else reports.
    public static func hasSufficientMemory(_ physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes >= minimumMemoryBytes
    }
}
