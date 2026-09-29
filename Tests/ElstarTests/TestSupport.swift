import Foundation
import Elstar

// MARK: - Fake native services

final class FakeRemindersService: AppleRemindersService, @unchecked Sendable {
    var listsResult: [AppleReminderListRecord] = []
    var remindersResult: [AppleReminderRecord] = []
    var error: AppleToolError?

    func authorizationStatus() async -> AppleNativeAuthorization { .authorized }
    func requestFullAccess() async throws {}
    func lists() async throws -> [AppleReminderListRecord] {
        if let error { throw error }
        return listsResult
    }
    func reminders(listID: String?, limit: Int) async throws -> [AppleReminderRecord] {
        if let error { throw error }
        return Array(remindersResult.prefix(limit))
    }
    func reminder(id: String) async throws -> AppleReminderRecord? {
        if let error { throw error }
        return remindersResult.first { $0.id == id }
    }
}

final class FakeCalendarService: AppleCalendarService, @unchecked Sendable {
    var eventsResult: [AppleCalendarEventRecord] = []
    var error: AppleToolError?

    func authorizationStatus() async -> AppleNativeAuthorization { .authorized }
    func requestFullAccess() async throws {}
    func events(in query: AppleCalendarRangeQuery, limit: Int) async throws -> [AppleCalendarEventRecord] {
        if let error { throw error }
        return Array(eventsResult.prefix(limit))
    }
    func event(id: String) async throws -> AppleCalendarEventRecord? {
        if let error { throw error }
        return eventsResult.first { $0.id == id }
    }
}

final class FakePlacesService: ApplePlacesService, @unchecked Sendable {
    var searchResult: [ApplePlaceRecord] = []
    var currentPlaceResult: ApplePlaceRecord?
    var openedRequests: [AppleDirectionsRequest] = []
    var error: AppleToolError?

    func locationAuthorizationStatus() async -> AppleNativeAuthorization { .authorized }
    func search(_ request: AppleNearbyPlacesRequest) async throws -> [ApplePlaceRecord] {
        if let error { throw error }
        return searchResult
    }
    func currentPlace(_ request: AppleCurrentPlaceRequest) async throws -> ApplePlaceRecord {
        if let error { throw error }
        return currentPlaceResult ?? ApplePlaceRecord(id: "current", name: "Current", latitude: 1, longitude: 2)
    }
    func openInMaps(_ request: AppleDirectionsRequest) async throws {
        if let error { throw error }
        openedRequests.append(request)
    }
}

final class FakeWeatherService: AppleWeatherService, @unchecked Sendable {
    var snapshot = AppleWeatherSnapshot(
        locationName: "Cupertino",
        condition: "Clear",
        temperatureCelsius: 21,
        forecast: [],
        attributionText: "Weather data by Apple Weather"
    )
    var error: AppleToolError?

    func isAvailable() -> Bool { true }
    func weather(for request: AppleWeatherRequest) async throws -> AppleWeatherSnapshot {
        if let error { throw error }
        return snapshot
    }
}

final class FakeWebFetchService: AppleWebFetchService, @unchecked Sendable {
    var page = AppleFetchedPage(sourceURL: URL(string: "https://example.com")!, title: "Example", text: "Hello", links: [])
    var error: AppleToolError?

    func fetch(_ request: AppleFetchWebPageRequest) async throws -> AppleFetchedPage {
        if let error { throw error }
        return page
    }
}

extension AppleToolServices {
    static func fake(
        reminders: FakeRemindersService = FakeRemindersService(),
        calendar: FakeCalendarService = FakeCalendarService(),
        places: FakePlacesService = FakePlacesService(),
        weather: FakeWeatherService = FakeWeatherService(),
        webFetch: FakeWebFetchService = FakeWebFetchService()
    ) -> AppleToolServices {
        AppleToolServices(reminders: reminders, calendar: calendar, places: places, weather: weather, webFetch: webFetch)
    }
}

// MARK: - Recording seams

final class RecordingEventSink: HarnessToolEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _deltas: [ToolActivity] = []
    private var _receipts: [AppleToolReceipt] = []
    private var _interactions: [PendingInteraction] = []
    private var _resolved: [String] = []

    var deltas: [ToolActivity] { lock.lock(); defer { lock.unlock() }; return _deltas }
    var receipts: [AppleToolReceipt] { lock.lock(); defer { lock.unlock() }; return _receipts }
    var interactions: [PendingInteraction] { lock.lock(); defer { lock.unlock() }; return _interactions }
    var resolved: [String] { lock.lock(); defer { lock.unlock() }; return _resolved }

    func actionReceipt(_ key: HarnessConversationKey, _ receipt: AppleToolReceipt) {
        lock.lock(); _receipts.append(receipt); lock.unlock()
    }
    func interactionRequested(_ key: HarnessConversationKey, _ interaction: PendingInteraction) {
        lock.lock(); _interactions.append(interaction); lock.unlock()
    }
    func interactionResolved(_ key: HarnessConversationKey, requestID: String) {
        lock.lock(); _resolved.append(requestID); lock.unlock()
    }
    func toolDelta(_ key: HarnessConversationKey, messageID: String, part: ToolActivity) {
        lock.lock(); _deltas.append(part); lock.unlock()
    }
}

final class RecordingTracker: HarnessActiveOperationTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var _active: [String: HarnessConversationKey] = [:]
    private var _cleared: [String] = []

    var activeIDs: [String] { lock.lock(); defer { lock.unlock() }; return Array(_active.keys) }
    var cleared: [String] { lock.lock(); defer { lock.unlock() }; return _cleared }

    func recordActiveKey(_ operationID: String, key: HarnessConversationKey) {
        lock.lock(); _active[operationID] = key; lock.unlock()
    }
    func clearActiveKey(_ operationID: String) {
        lock.lock(); _active[operationID] = nil; _cleared.append(operationID); lock.unlock()
    }
}

// MARK: - Fetch doubles

final class FakeHTTPClient: AppleWebFetchHTTPClient, @unchecked Sendable {
    nonisolated(unsafe) private var _requestedURLs: [URL] = []
    nonisolated(unsafe) var hops: [URL: AppleHTTPHop] = [:]

    var requestedURLs: [URL] { _requestedURLs }

    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> AppleHTTPHop {
        _requestedURLs.append(url)
        guard let hop = hops[url] else { throw AppleToolError.network("No fake hop for \(url).") }
        return hop
    }
}

final class FakeHostResolver: AppleHostResolving, @unchecked Sendable {
    nonisolated(unsafe) var addresses: [String] = ["93.184.216.34"]
    func resolve(host: String) async throws -> [String] { addresses }
}

// MARK: - Planner / dispatcher doubles

final class ScriptedPlanner: AppleAgentPlanner, @unchecked Sendable {
    nonisolated(unsafe) private var steps: [AppleAgentStep]
    nonisolated(unsafe) var planResult: AppleAgentPlan

    init(plan: AppleAgentPlan, steps: [AppleAgentStep] = []) {
        self.planResult = plan
        self.steps = steps
    }

    func plan(task: String, history: [AppleModelTurn]) async throws -> AppleAgentPlan {
        planResult
    }

    func nextStep(_ context: AppleAgentContext) async throws -> AppleAgentStep {
        guard !steps.isEmpty else { return .finish }
        return steps.removeFirst()
    }
}

final class FakeDispatcher: AppleToolDispatching, @unchecked Sendable {
    nonisolated(unsafe) private var _performed: [AppleToolRequest] = []
    nonisolated(unsafe) var result: AppleToolResult?
    /// When true, `perform` returns nil to model a person declining.
    nonisolated(unsafe) var returnsNil = false

    var performed: [AppleToolRequest] { _performed }

    func perform(_ request: AppleToolRequest) async -> AppleToolResult? {
        _performed.append(request)
        if returnsNil { return nil }
        return result ?? AppleToolResult(summary: "Done.")
    }
}
