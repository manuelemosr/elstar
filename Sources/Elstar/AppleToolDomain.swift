import Foundation

// MARK: - Tool families

/// The six on-device capability families the harness can execute. They are
/// exposed to a planner as a small number of compact tools, each carrying
/// several bounded operations, rather than dozens of schemas.
public nonisolated enum AppleToolFamily: String, CaseIterable, Codable, Sendable {
    case reminders
    case calendar
    case places
    case weather
    case webfetch
    case time

    public var displayName: String {
        switch self {
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .places: "Places"
        case .weather: "Weather"
        case .webfetch: "Web page"
        case .time: "Time"
        }
    }
}

// MARK: - Concrete operations

/// A stable, concrete operation identity. Goals and executions are matched on
/// this (not merely read/write family), so a current-location read can never
/// satisfy a restaurant-search goal and a reminder-list read can never satisfy
/// a list-reminders goal.
public nonisolated enum AppleToolOperation: String, CaseIterable, Codable, Sendable {
    case currentTime = "time.current"
    case listReminderLists = "reminders.list_lists"
    case listReminders = "reminders.list"
    case listCalendarEvents = "calendar.list"
    case calendarAvailability = "calendar.availability"
    case searchNearbyPlaces = "places.search"
    case currentPlace = "places.current"
    case directions = "places.directions"
    case weather = "weather.current"
    case fetchWebPage = "webfetch.read"

    /// Whether the operation changes user-visible state and therefore requires
    /// an explicit per-action confirmation before it runs. No built-in
    /// operation mutates state: opening a map app is now a host UI choice, not
    /// a harness effect. Hosts may add mutating operations that use the
    /// confirmation machinery.
    public var isMutation: Bool {
        false
    }

    public var family: AppleToolFamily {
        switch self {
        case .currentTime: .time
        case .listReminderLists, .listReminders: .reminders
        case .listCalendarEvents, .calendarAvailability: .calendar
        case .searchNearbyPlaces, .currentPlace, .directions: .places
        case .weather: .weather
        case .fetchWebPage: .webfetch
        }
    }

    public var displayName: String {
        switch self {
        case .currentTime: "current time"
        case .listReminderLists: "list reminder lists"
        case .listReminders: "list reminders"
        case .listCalendarEvents: "list calendar events"
        case .calendarAvailability: "check calendar availability"
        case .searchNearbyPlaces: "search for nearby places"
        case .currentPlace: "find the current place"
        case .directions: "open directions"
        case .weather: "get weather"
        case .fetchWebPage: "read a web page"
        }
    }
}

// MARK: - Shared anchors

/// Where a location-scoped read should look. Location is only requested when
/// an anchor of `.currentLocation` is chosen; a named place or coordinate works
/// with location permission denied.
public nonisolated enum ApplePlaceAnchor: Equatable, Sendable {
    case currentLocation
    case named(String)
    case coordinate(latitude: Double, longitude: Double)

    /// Stable, content-free key for dedupe/confirmation.
    public var key: String {
        switch self {
        case .currentLocation: "current"
        case .named(let name): "name:\(name.lowercased())"
        case .coordinate(let lat, let lon): "coord:\(lat),\(lon)"
        }
    }
}

public nonisolated enum AppleDirectionsMode: String, CaseIterable, Codable, Sendable {
    case driving
    case walking
    case transit

    public var mapsLaunchKey: String {
        switch self {
        case .driving: "MKLaunchOptionsDirectionsModeDriving"
        case .walking: "MKLaunchOptionsDirectionsModeWalking"
        case .transit: "MKLaunchOptionsDirectionsModeTransit"
        }
    }
}

public nonisolated enum AppleWeatherRequestKind: Equatable, Sendable {
    case current
    case forecast(days: Int)
    case hourly(hours: Int)
}

// MARK: - Requests

/// A parsed, validated tool operation. Every mutating case carries the exact
/// human-readable values shown on the confirmation card; nothing runs before
/// the user allows it.
public nonisolated enum AppleToolRequest: Equatable, Sendable {
    // Reminders
    case listReminderLists
    case listReminders(listID: String?)
    // Calendar
    case listCalendarEvents(AppleCalendarRangeQuery)
    case calendarAvailability(AppleCalendarRangeQuery)
    // Places
    case searchNearbyPlaces(AppleNearbyPlacesRequest)
    case directions(AppleDirectionsRequest)
    // Weather
    case weather(AppleWeatherRequest)
    // Web fetch
    case fetchWebPage(AppleFetchWebPageRequest)
    // Time
    case currentTime
    // Current place
    case currentPlace(AppleCurrentPlaceRequest)

    public var family: AppleToolFamily {
        switch self {
        case .listReminderLists, .listReminders: .reminders
        case .listCalendarEvents, .calendarAvailability: .calendar
        case .searchNearbyPlaces, .directions, .currentPlace: .places
        case .weather: .weather
        case .fetchWebPage: .webfetch
        case .currentTime: .time
        }
    }

    /// Whether the operation changes user-visible state and therefore requires
    /// an explicit per-action confirmation before it runs.
    public var isMutation: Bool { operation.isMutation }

    /// The concrete operation identity used for goal matching.
    public var operation: AppleToolOperation {
        switch self {
        case .listReminderLists: .listReminderLists
        case .listReminders: .listReminders
        case .listCalendarEvents: .listCalendarEvents
        case .calendarAvailability: .calendarAvailability
        case .searchNearbyPlaces: .searchNearbyPlaces
        case .currentPlace: .currentPlace
        case .directions: .directions
        case .weather: .weather
        case .fetchWebPage: .fetchWebPage
        case .currentTime: .currentTime
        }
    }

    /// Bounded, deterministic confirmation copy with the exact values. Native
    /// approvals never offer "Always", so this is a one-shot grant. Used only
    /// by host-added mutating operations; the built-in catalog has none.
    public var confirmationTitle: String { "Allow this action?" }

    public var confirmationDetail: String? { nil }
}

// MARK: - Calendar requests

public nonisolated struct AppleCalendarRangeQuery: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var calendarID: String?

    public init(start: Date, end: Date, calendarID: String? = nil) {
        self.start = start
        self.end = end
        self.calendarID = calendarID
    }

}

// MARK: - Places / weather requests

public nonisolated struct AppleNearbyPlacesRequest: Equatable, Sendable {
    public var query: String
    public var anchor: ApplePlaceAnchor
    public var limit: Int

    public init(query: String, anchor: ApplePlaceAnchor, limit: Int) {
        self.query = query
        self.anchor = anchor
        self.limit = limit
    }

}

/// Resolve the device's own current place: CLLocation plus an optional reverse
/// geocode. Never a text search. A valid coordinate with a failed address
/// lookup still yields a map with an honest address-unavailable state.
public nonisolated struct AppleCurrentPlaceRequest: Equatable, Sendable {
    public var reverseGeocode: Bool

    public init(reverseGeocode: Bool = true) { self.reverseGeocode = reverseGeocode }
}

public nonisolated struct AppleDirectionsRequest: Equatable, Sendable {
    public var destinationID: String
    public var destinationName: String
    public var destinationAddress: String?
    public var mode: AppleDirectionsMode

    public init(destinationID: String, destinationName: String, destinationAddress: String? = nil, mode: AppleDirectionsMode) {
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.destinationAddress = destinationAddress
        self.mode = mode
    }

}

public nonisolated struct AppleWeatherRequest: Equatable, Sendable {
    public var anchor: ApplePlaceAnchor
    public var kind: AppleWeatherRequestKind

    public init(anchor: ApplePlaceAnchor, kind: AppleWeatherRequestKind) {
        self.anchor = anchor
        self.kind = kind
    }

}

// MARK: - Web fetch request

public nonisolated struct AppleFetchWebPageRequest: Equatable, Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

}

/// A prepared directions destination. The harness never opens a map app; it
/// reports the destination and mode so the host can offer the person a choice
/// of the map apps installed on the device.
public nonisolated struct AppleDirectionsPresentation: Codable, Equatable, Hashable, Sendable {
    public var destinationID: String
    public var destinationName: String
    public var destinationAddress: String?
    public var latitude: Double?
    public var longitude: Double?
    public var mode: AppleDirectionsMode

    public init(destinationID: String, destinationName: String, destinationAddress: String? = nil, latitude: Double? = nil, longitude: Double? = nil, mode: AppleDirectionsMode) {
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.destinationAddress = destinationAddress
        self.latitude = latitude
        self.longitude = longitude
        self.mode = mode
    }

}

/// WeatherKit attribution the app must display. Persisted on the weather tool
/// activity so a reopened conversation still shows it; never parsed back out
/// of the model's prose.
public nonisolated struct AppleWeatherPresentation: Codable, Equatable, Hashable, Sendable {
    public var locationName: String
    public var attributionText: String
    public var attributionURL: URL?
    public var attributionImageURL: URL?

    public init(locationName: String, attributionText: String, attributionURL: URL? = nil, attributionImageURL: URL? = nil) {
        self.locationName = locationName
        self.attributionText = attributionText
        self.attributionURL = attributionURL
        self.attributionImageURL = attributionImageURL
    }

}

// MARK: - Results

/// One line a tool card renders under the tool's name.
public nonisolated struct AppleToolDisplayItem: Equatable, Sendable, Codable {
    public var title: String
    public var subtitle: String?
    /// Extra model-facing context (e.g. an event's location) that the card can
    /// render and the model can answer from, without a second tool call.
    public var detail: String? = nil
    public var reference: String?

    public init(title: String, subtitle: String? = nil, detail: String? = nil, reference: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.reference = reference
    }

}
/// Durable proof that a side effect actually happened, so a completed action is
/// never repeated. `nativeID` is the returned framework identifier (reminder,
/// event UUID) when one exists.
public nonisolated enum AppleToolStatus: String, Codable, Equatable, Sendable {
    /// The effect was applied and (where supported) read back.
    case confirmed
    /// The user must do something (grant permission, choose an option).
    case needsUserAction
    /// The action did not happen.
    case failed
    /// The outcome could not be determined; never auto-retried.
    case uncertain
}

public nonisolated struct AppleToolReceipt: Equatable, Hashable, Sendable, Codable {
    public var operationID: String
    public var family: AppleToolFamily
    public var action: String
    public var nativeID: String?
    public var summary: String
    public var recordedAt: Date
    /// Exact human-readable values shown on the outcome card (destination/time
    /// for directions, and similar).
    public var detail: String?
    public var status: AppleToolStatus
    /// Additive conversation scope. Old (unscoped) entries decode as nil and
    /// are never treated as belonging to any chat's context.
    public var conversationID: String?
    /// Additive originating assistant message id. Lets the outcome card attach
    /// to the exact row it came from; nil on legacy receipts falls back to the
    /// conversation's last assistant row.
    public var assistantMessageID: String?

    /// Backward-compatible decoding: documents written before structured
    /// statuses default to a confirmed committed effect.
    enum CodingKeys: String, CodingKey {
        case operationID, family, action, nativeID, summary, recordedAt, detail, status, outcome
        case conversationID = "conversation_id"
        case assistantMessageID = "assistant_message_id"
    }

    public init(operationID: String, family: AppleToolFamily, action: String, nativeID: String?, summary: String, recordedAt: Date, detail: String? = nil, status: AppleToolStatus = .confirmed, conversationID: String? = nil, assistantMessageID: String? = nil) {
        self.operationID = operationID
        self.family = family
        self.action = action
        self.nativeID = nativeID
        self.summary = summary
        self.recordedAt = recordedAt
        self.detail = detail
        self.status = status
        self.conversationID = conversationID
        self.assistantMessageID = assistantMessageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decode(String.self, forKey: .operationID)
        family = try container.decode(AppleToolFamily.self, forKey: .family)
        action = try container.decode(String.self, forKey: .action)
        nativeID = try container.decodeIfPresent(String.self, forKey: .nativeID)
        summary = try container.decode(String.self, forKey: .summary)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        assistantMessageID = try container.decodeIfPresent(String.self, forKey: .assistantMessageID)
        if let status = try container.decodeIfPresent(AppleToolStatus.self, forKey: .status) {
            self.status = status
        } else {
            self.status = .confirmed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(family, forKey: .family)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(nativeID, forKey: .nativeID)
        try container.encode(summary, forKey: .summary)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encodeIfPresent(assistantMessageID, forKey: .assistantMessageID)
    }
}

/// The result handed back to the coordinator: a concise, model-facing summary
/// plus bounded display items and an optional effect receipt. Never the full
/// web page or a device-store dump.
public nonisolated struct AppleToolResult: Equatable, Sendable {
    public var summary: String
    public var items: [AppleToolDisplayItem]
    public var receipt: AppleToolReceipt?
    public var status: AppleToolStatus
    /// Structured, persistable map payload for inline rendering. Never parsed
    /// back out of `summary`.
    public var mapPresentation: AppleMapPresentation?
    /// Structured, persistable directions destination for the host to render as
    /// a map-app chooser. Never parsed back out of `summary`.
    public var directionsPresentation: AppleDirectionsPresentation?
    /// Structured, persistable WeatherKit attribution for the weather card.
    public var weatherPresentation: AppleWeatherPresentation?

    public init(summary: String, items: [AppleToolDisplayItem] = [], receipt: AppleToolReceipt? = nil, status: AppleToolStatus = .confirmed, mapPresentation: AppleMapPresentation? = nil, directionsPresentation: AppleDirectionsPresentation? = nil, weatherPresentation: AppleWeatherPresentation? = nil) {
        self.summary = summary
        self.items = items
        self.receipt = receipt
        self.status = status
        self.mapPresentation = mapPresentation
        self.directionsPresentation = directionsPresentation
        self.weatherPresentation = weatherPresentation
    }

    /// The bounded text placed in the model transcript / tool card.
    public var modelText: String {
        var text = summary
        if !items.isEmpty {
            text += "\n" + items.prefix(12).map { item in
                var line = "- \(item.title)"
                if let subtitle = item.subtitle { line += " (\(subtitle))" }
                if let detail = item.detail, !detail.isEmpty { line += " - \(detail)" }
                return line
            }.joined(separator: "\n")
        }
        return text
    }
}

// MARK: - Errors

/// Typed native-tool failures. Each maps to honest, actionable copy; none is a
/// silent success.
public nonisolated enum AppleToolError: Error, Equatable, Sendable {
    case permissionDenied(String)
    case permissionRestricted(String)
    case serviceDisabled(String)
    case notAvailable(String)
    case invalidInput(String)
    case notFound(String)
    case network(String)
    case cancelled
    case unsupportedFormat(String)
    case blocked(String)
    case uncertain(String)

    public var userMessage: String {
        switch self {
        case .permissionDenied(let what): "\(what) permission was denied. Enable it in Settings, then try again."
        case .permissionRestricted(let what): "\(what) is restricted on this device."
        case .serviceDisabled(let what): "\(what) is turned off. Enable it, then try again."
        case .notAvailable(let what): what
        case .invalidInput(let detail): detail
        case .notFound(let detail): detail
        case .network(let detail): detail
        case .cancelled: "The action was cancelled."
        case .unsupportedFormat(let detail): detail
        case .blocked(let detail): detail
        case .uncertain(let detail): detail
        }
    }
}

// MARK: - Date formatting

/// Human-readable, time-zone-aware date copy for confirmation cards. Uses the
/// user's current calendar so DST and locale are honored.
public nonisolated enum AppleDateFormatting {
    public static func spoken(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func spokenDay(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

nonisolated extension AppleDirectionsMode {
    public var displayName: String {
        switch self {
        case .driving: "driving"
        case .walking: "walking"
        case .transit: "transit"
        }
    }
}
nonisolated extension AppleToolReceipt: Identifiable {
    public var id: String { operationID }
}
