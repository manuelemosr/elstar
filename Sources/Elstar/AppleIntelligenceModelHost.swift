import Foundation

/// Pure device-capability check for Localzie's advanced on-device model.
///
/// Apple Intelligence itself is available on every eligible iPhone (the
/// base 3B foundation model). The advanced on-device variant (AFM 3 Core
/// Advanced: 20 billion parameters, sparse, stored in flash) needs, in
/// addition, at least 12 GiB of physical memory (Apple documents the
/// floor as an A19 Pro-class chip with 12 GiB or more). The chip verdict
/// is delegated to the operating system's own model-availability answer
/// (the app target reads it from the FoundationModels framework), so only
/// the memory floor lives here, where it stays testable without any Apple
/// framework. It feeds the per-device model options (which Qwen/Flux
/// class a device can run), not the availability of the connection.
public enum AppleIntelligenceModelHost {
    /// Apple's documented floor for the advanced on-device model:
    /// at least 12 GiB of physical memory.
    public static let minimumMemoryBytes: UInt64 = 12 * 1024 * 1024 * 1024

    /// Conservative physical-memory check for advanced-variant-class
    /// models (20B sparse, 8B dense at 4-bit, 9B image models).
    public static func hasSufficientMemory(_ physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes >= minimumMemoryBytes
    }
}
