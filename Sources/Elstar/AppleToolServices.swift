import Foundation

// MARK: - Authorization

public nonisolated enum AppleNativeAuthorization: String, Equatable, Sendable, Codable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case limited
}

// MARK: - Records

public nonisolated struct AppleReminderRecord: Equatable, Sendable {
    public var id: String
    public var title: String
    public var due: Date?
    /// Whether the reminder has any alert attached. Reads only report this; the
    /// harness never schedules or edits alerts.
    public var hasAlert: Bool
    public var listID: String?
    public var listTitle: String?
    public var isCompleted: Bool

    public init(id: String, title: String, due: Date? = nil, hasAlert: Bool = false, listID: String? = nil, listTitle: String? = nil, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.due = due
        self.hasAlert = hasAlert
        self.listID = listID
        self.listTitle = listTitle
        self.isCompleted = isCompleted
    }

}

public nonisolated struct AppleReminderListRecord: Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

}

public nonisolated struct AppleCalendarEventRecord: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var calendarID: String?
    /// Human-readable calendar name shown on the confirmation and receipt.
    public var calendarTitle: String? = nil
    /// True when the event's calendar accepts new events.
    public var isWritable: Bool = true

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, location: String? = nil, notes: String? = nil, calendarID: String? = nil, calendarTitle: String? = nil, isWritable: Bool = true) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.isWritable = isWritable
    }

}

public nonisolated struct ApplePlaceRecord: Equatable, Sendable {
    public var id: String
    public var name: String
    public var address: String?
    public var distanceMeters: Double?
    public var website: URL?
    public var latitude: Double
    public var longitude: Double
    /// True when this is the device's own current position.
    public var isCurrentPosition: Bool = false
    /// Horizontal accuracy in meters for a current-position record.
    public var accuracyMeters: Double? = nil
    /// True when a coordinate exists but reverse geocoding did not produce an
    /// address (honest "address unavailable" state, map still shown).
    public var addressUnavailable: Bool = false

    public init(id: String, name: String, address: String? = nil, distanceMeters: Double? = nil, website: URL? = nil, latitude: Double, longitude: Double, isCurrentPosition: Bool = false, accuracyMeters: Double? = nil, addressUnavailable: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.distanceMeters = distanceMeters
        self.website = website
        self.latitude = latitude
        self.longitude = longitude
        self.isCurrentPosition = isCurrentPosition
        self.accuracyMeters = accuracyMeters
        self.addressUnavailable = addressUnavailable
    }

}

public nonisolated struct AppleWeatherSnapshot: Equatable, Sendable {
    public var locationName: String
    public var condition: String
    public var temperatureCelsius: Double
    public var highCelsius: Double?
    public var lowCelsius: Double?
    public var forecast: [AppleWeatherDay]
    public var hourly: [AppleWeatherHour]
    /// WeatherKit attribution: the legal text and link that must be displayed.
    public var attributionText: String
    public var attributionURL: URL?
    public var attributionImageURL: URL?

    public init(locationName: String, condition: String, temperatureCelsius: Double, highCelsius: Double? = nil, lowCelsius: Double? = nil, forecast: [AppleWeatherDay], attributionText: String, attributionURL: URL? = nil, attributionImageURL: URL? = nil, hourly: [AppleWeatherHour] = []) {
        self.locationName = locationName
        self.condition = condition
        self.temperatureCelsius = temperatureCelsius
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.forecast = forecast
        self.attributionText = attributionText
        self.attributionURL = attributionURL
        self.attributionImageURL = attributionImageURL
        self.hourly = hourly
    }

}

public nonisolated struct AppleWeatherDay: Equatable, Sendable {
    public var day: String
    public var condition: String
    public var highCelsius: Double
    public var lowCelsius: Double

    public init(day: String, condition: String, highCelsius: Double, lowCelsius: Double) {
        self.day = day
        self.condition = condition
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
    }

}

public nonisolated struct AppleWeatherHour: Equatable, Sendable {
    public var time: String
    public var condition: String
    public var temperatureCelsius: Double
    /// 0...1 chance of precipitation at this hour.
    public var precipitationChance: Double

    public init(time: String, condition: String, temperatureCelsius: Double, precipitationChance: Double) {
        self.time = time
        self.condition = condition
        self.temperatureCelsius = temperatureCelsius
        self.precipitationChance = precipitationChance
    }

}

// MARK: - Service protocols

/// Reminders via EventKit. Full-reminders access is requested only when a
/// reminder operation is first attempted.
public nonisolated protocol AppleRemindersService: AnyObject, Sendable {
    func authorizationStatus() async -> AppleNativeAuthorization
    func requestFullAccess() async throws
    func lists() async throws -> [AppleReminderListRecord]
    func reminders(listID: String?, limit: Int) async throws -> [AppleReminderRecord]
    /// Fetch one reminder by its persisted ID for a live detail view. Nil when
    /// it no longer exists; throws when access is denied.
    func reminder(id: String) async throws -> AppleReminderRecord?
}

/// Calendar events via EventKit. Bounded date-range queries only.
public nonisolated protocol AppleCalendarService: AnyObject, Sendable {
    func authorizationStatus() async -> AppleNativeAuthorization
    func requestFullAccess() async throws
    func events(in query: AppleCalendarRangeQuery, limit: Int) async throws -> [AppleCalendarEventRecord]
    /// Fetch one event by its persisted ID for readback and live detail. Nil
    /// when it no longer exists; throws when access is denied.
    func event(id: String) async throws -> AppleCalendarEventRecord?
}

/// Places via MapKit. Location is requested only for `.currentLocation` or a
/// current-place read.
public nonisolated protocol ApplePlacesService: AnyObject, Sendable {
    func locationAuthorizationStatus() async -> AppleNativeAuthorization
    func search(_ request: AppleNearbyPlacesRequest) async throws -> [ApplePlaceRecord]
    /// The device's own current place: a real CLLocation coordinate plus an
    /// optional reverse geocode. Never a text search.
    func currentPlace(_ request: AppleCurrentPlaceRequest) async throws -> ApplePlaceRecord
}

public nonisolated protocol AppleWeatherService: AnyObject, Sendable {
    func isAvailable() -> Bool
    func weather(for request: AppleWeatherRequest) async throws -> AppleWeatherSnapshot
}

/// Fetches one public HTTPS page and returns bounded readable text plus real
/// menu/links. Never executes JavaScript or bypasses authentication.
public nonisolated protocol AppleWebFetchService: AnyObject, Sendable {
    func fetch(_ request: AppleFetchWebPageRequest) async throws -> AppleFetchedPage
}

public nonisolated struct AppleFetchedPage: Equatable, Sendable {
    public var sourceURL: URL
    public var title: String?
    public var text: String
    public var links: [AppleFetchedLink]

    public init(sourceURL: URL, title: String? = nil, text: String, links: [AppleFetchedLink]) {
        self.sourceURL = sourceURL
        self.title = title
        self.text = text
        self.links = links
    }

}

public nonisolated struct AppleFetchedLink: Equatable, Sendable {
    public var text: String
    public var url: URL

    public init(text: String, url: URL) {
        self.text = text
        self.url = url
    }

}

// MARK: - Services container

/// The five on-device service implementations, injected so the backend is
/// fully testable with fakes.
public nonisolated struct AppleToolServices: @unchecked Sendable {
    public var reminders: any AppleRemindersService
    public var calendar: any AppleCalendarService
    public var places: any ApplePlacesService
    public var weather: any AppleWeatherService
    public var webFetch: any AppleWebFetchService

    public init(reminders: any AppleRemindersService, calendar: any AppleCalendarService, places: any ApplePlacesService, weather: any AppleWeatherService, webFetch: any AppleWebFetchService) {
        self.reminders = reminders
        self.calendar = calendar
        self.places = places
        self.weather = weather
        self.webFetch = webFetch
    }

    /// A tool set whose every operation fails honestly as unavailable. Used
    /// when no native service provider is installed (pure package/tests); a
    /// server connection never silently pretends a device tool succeeded.
    public static func unavailable() -> AppleToolServices {
        AppleToolServices(
            reminders: UnavailableAppleRemindersService(),
            calendar: UnavailableAppleCalendarService(),
            places: UnavailableApplePlacesService(),
            weather: UnavailableAppleWeatherService(),
            webFetch: UnavailableAppleWebFetchService()
        )
    }
}

// MARK: - Unavailable tool services

private func appleToolsUnavailable(_ what: String) -> AppleToolError {
    .notAvailable("\(what) isn't available on this platform.")
}

public nonisolated final class UnavailableAppleRemindersService: AppleRemindersService, @unchecked Sendable {
    public func authorizationStatus() async -> AppleNativeAuthorization { .restricted }
    public func requestFullAccess() async throws { throw appleToolsUnavailable("Reminders") }
    public func lists() async throws -> [AppleReminderListRecord] { throw appleToolsUnavailable("Reminders") }
    public func reminders(listID: String?, limit: Int) async throws -> [AppleReminderRecord] { throw appleToolsUnavailable("Reminders") }
    public func reminder(id: String) async throws -> AppleReminderRecord? { throw appleToolsUnavailable("Reminders") }
}

public nonisolated final class UnavailableAppleCalendarService: AppleCalendarService, @unchecked Sendable {
    public func authorizationStatus() async -> AppleNativeAuthorization { .restricted }
    public func requestFullAccess() async throws { throw appleToolsUnavailable("Calendar") }
    public func events(in query: AppleCalendarRangeQuery, limit: Int) async throws -> [AppleCalendarEventRecord] { throw appleToolsUnavailable("Calendar") }
    public func event(id: String) async throws -> AppleCalendarEventRecord? { throw appleToolsUnavailable("Calendar") }
}

public nonisolated final class UnavailableApplePlacesService: ApplePlacesService, @unchecked Sendable {
    public func locationAuthorizationStatus() async -> AppleNativeAuthorization { .restricted }
    public func search(_ request: AppleNearbyPlacesRequest) async throws -> [ApplePlaceRecord] { throw appleToolsUnavailable("Places") }
    public func currentPlace(_ request: AppleCurrentPlaceRequest) async throws -> ApplePlaceRecord { throw appleToolsUnavailable("Places") }
}

public nonisolated final class UnavailableAppleWeatherService: AppleWeatherService, @unchecked Sendable {
    public func isAvailable() -> Bool { false }
    public func weather(for request: AppleWeatherRequest) async throws -> AppleWeatherSnapshot { throw appleToolsUnavailable("Weather") }
}

public nonisolated final class UnavailableAppleWebFetchService: AppleWebFetchService, @unchecked Sendable {
    public func fetch(_ request: AppleFetchWebPageRequest) async throws -> AppleFetchedPage { throw appleToolsUnavailable("Web reading") }
}

// MARK: - Single-resume guard

/// Guards a callback wrapped in a checked continuation when the framework may
/// invoke that callback more than once (e.g. `EKEventStore.fetchReminders`
/// returns a cancel token precisely because its completion can fire repeatedly).
/// Only the first invocation wins; later ones are ignored instead of
/// double-resuming the continuation, which would crash at runtime.
public nonisolated final class AppleSingleResumeGuard: @unchecked Sendable {
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

// MARK: - Model runtime seam

public nonisolated enum AppleModelRole: String, Sendable {
    case user
    case assistant
}

public nonisolated struct AppleModelTurn: Equatable, Sendable {
    public var role: AppleModelRole
    public var text: String

    public init(role: AppleModelRole, text: String) {
        self.role = role
        self.text = text
    }

}

/// The dispatcher the FoundationModels bridge calls for every tool invocation
/// the model decides to make. Implemented by the backend's coordinator.
public nonisolated protocol AppleToolDispatching: AnyObject, Sendable {
    /// Runs (or refuses) one parsed operation. Returns the bounded result text
    /// the model sees, or nil when the user denied or the tool was cancelled.
    func perform(_ request: AppleToolRequest) async -> AppleToolResult?
}

/// The real FoundationModels bridge. The pure backend depends only on this
/// small seam; the app installs the concrete implementation.
public nonisolated protocol AppleFoundationModelRuntime: AnyObject, Sendable {
    func availability() -> AppleIntelligenceAvailability

    /// Streams one reply. `onDelta` receives real partial text snapshots in
    /// order. Tool calls are handled inside the bridge through `dispatcher`.
    func streamReply(
        instructions: String,
        history: [AppleModelTurn],
        prompt: String,
        includeTools: Bool,
        dispatcher: any AppleToolDispatching,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws

    /// A tools-free, cancellable title turn sharing the connection's single
    /// generation gate.
    func generateTitle(history: [AppleModelTurn]) async throws -> String

    /// Streams one reply and additionally forwards real reasoning deltas when
    /// the underlying model exposes them. The default forwards only text, so
    /// runtimes that have no separate reasoning channel (and the on-device
    /// model) keep the previous behavior.
    func streamReply(
        instructions: String,
        history: [AppleModelTurn],
        prompt: String,
        includeTools: Bool,
        dispatcher: any AppleToolDispatching,
        onReasoningDelta: @escaping @Sendable (String) -> Void,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws
}

nonisolated extension AppleFoundationModelRuntime {
    public func streamReply(
        instructions: String,
        history: [AppleModelTurn],
        prompt: String,
        includeTools: Bool,
        dispatcher: any AppleToolDispatching,
        onReasoningDelta: @escaping @Sendable (String) -> Void,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = onReasoningDelta
        try await streamReply(
            instructions: instructions,
            history: history,
            prompt: prompt,
            includeTools: includeTools,
            dispatcher: dispatcher,
            onDelta: onDelta
        )
    }
}