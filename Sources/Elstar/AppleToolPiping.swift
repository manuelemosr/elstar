import Foundation

// MARK: - Journal

/// Durable record of external effects this app performed. Its job is to make a
/// completed action visible after a relaunch and to make an ambiguous outcome
/// explicit, so a mutation is never silently replayed. One file per connection.
public actor AppleToolJournal {
    private let fileURL: URL
    private var receipts: [AppleToolReceipt] = []
    private var loaded = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultURL(connectionID: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Elstar/ToolJournal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(connectionID.uuidString).json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([AppleToolReceipt].self, from: data) else { return }
        receipts = decoded
    }

    public func record(_ receipt: AppleToolReceipt) {
        ensureLoaded()
        receipts.append(receipt)
        if receipts.count > 200 { receipts = Array(receipts.suffix(200)) }
        // A failed disk write leaves the receipt in memory only; it still
        // guards against a within-session replay but is not durable.
        try? encoder.encode(receipts).write(to: fileURL, options: .atomic)
    }

    public func all() -> [AppleToolReceipt] {
        ensureLoaded()
        return receipts
    }

    /// Concise, model-facing recap of committed effects so the model does not
    /// repeat an action the user already approved. Scoped to one conversation:
    /// unscoped legacy receipts are never attributed to a chat.
    public func committedSummary(conversationID: String?, limit: Int = 8) -> String? {
        ensureLoaded()
        let committed = receipts.filter { $0.status == .confirmed && $0.conversationID == conversationID }.suffix(limit)
        guard !committed.isEmpty else { return nil }
        return committed.map { receipt in
            var line = "- \(receipt.action): \(receipt.summary) [verified]"
            if let id = receipt.nativeID { line += " id=\(id)" }
            if let detail = receipt.detail { line += " (\(detail.replacingOccurrences(of: "\n", with: "; ")))" }
            return line
        }.joined(separator: "\n")
    }

    /// Unfinished or uncertain effects the model must not silently retry,
    /// scoped to one conversation.
    public func attentionSummary(conversationID: String?, limit: Int = 4) -> String? {
        ensureLoaded()
        let unresolved = receipts.filter { $0.status == .uncertain && $0.conversationID == conversationID }.suffix(limit)
        guard !unresolved.isEmpty else { return nil }
        return unresolved.map { "- \($0.action): \($0.summary) [outcome uncertain - do not retry]" }.joined(separator: "\n")
    }
}

// MARK: - Pending confirmations

/// Lock-protected map of request IDs to the continuation awaiting the user's
/// allow/deny. A denied or stale answer resumes with `false`; the map is
/// cleared on connection teardown.
public nonisolated final class AppleConfirmationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var pendingOrder: [String] = []

    public init() {}

    public func insert(_ id: String, _ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock(); defer { lock.unlock() }
        continuations[id] = continuation
        pendingOrder.append(id)
    }

    public func resolve(_ id: String, allowed: Bool) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        pendingOrder.removeAll { $0 == id }
        lock.unlock()
        continuation?.resume(returning: allowed)
    }

    public func cancelAll() {
        lock.lock()
        let all = continuations
        continuations.removeAll()
        pendingOrder.removeAll()
        lock.unlock()
        for (_, continuation) in all { continuation.resume(returning: false) }
    }

    public var pendingIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return pendingOrder
    }
}

/// Serializes mutating tool work and permission/sheet presentation so two
/// approved actions never overlap. An actor is reentrant across awaits, so the
/// gate must be an explicit busy flag plus a waiter queue held across the whole
/// operation; otherwise two concurrent calls would run concurrently and could
/// both present a system sheet.
public actor AppleOperationSerializer {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Backend

/// Lock-protected one-shot flag: returns true exactly once. Used to switch the
/// activity to `.writing` on the first streamed delta without a captured var.
public nonisolated final class AppleOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    public init() {}

    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
