import Foundation

// MARK: - Clock

/// Injectable wall clock. All time-dependent tool behavior reads "now" from
/// here so a turn never derives the current time from cached history and so
/// tests can advance the clock deterministically.
public nonisolated protocol AppleClock: Sendable {
    func now() -> Date
}

public nonisolated struct SystemAppleClock: AppleClock {
    public init() {}

    public func now() -> Date { Date() }
}

public nonisolated final class FixedAppleClock: AppleClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ date: Date) { self.current = date }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    public func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
}

// MARK: - Parsed instants

/// A parsed date plus whether the source string actually named a time of day.
/// A date-only value must never be silently turned into a midnight timed event.
public nonisolated struct AppleParsedInstant: Equatable, Sendable {
    public var date: Date
    public var hasTime: Bool

    public init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }

}

// MARK: - Relative ranges

public nonisolated enum AppleRelativeRange: Equatable, Sendable {
    case today
    case tomorrow
    case next7Days
}

// MARK: - Date resolution

/// Shared, time-zone and DST aware date/range resolution used by both the
/// model bridge and the executor. Keeping it in one place means a model
/// argument and the confirmation card can never disagree about what a date
/// means.
public nonisolated enum AppleDateResolution {
    public static func isoFractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    public static func iso() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// Parses a model-supplied date. Accepts zoned ISO 8601, a local
    /// (no-zone) date-time interpreted in the explicit device calendar's time
    /// zone, and a date-only value. Returns nil for anything else.
    public static func parse(_ text: String?, calendar: Calendar) -> AppleParsedInstant? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let date = isoFractional().date(from: raw) { return AppleParsedInstant(date: date, hasTime: true) }
        if let date = iso().date(from: raw) { return AppleParsedInstant(date: date, hasTime: true) }
        let zone = calendar.timeZone
        let localFormats: [(String, Bool)] = [
            ("yyyy-MM-dd'T'HH:mm:ss", true),
            ("yyyy-MM-dd'T'HH:mm", true),
            ("yyyy-MM-dd HH:mm:ss", true),
            ("yyyy-MM-dd HH:mm", true),
            ("yyyy-MM-dd", false),
        ]
        for (format, hasTime) in localFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = zone
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return AppleParsedInstant(date: date, hasTime: hasTime)
            }
        }
        return nil
    }

    /// Resolves a typed relative range to a bounded query. `today` is the
    /// start of day to the next start of day; ranges add whole days through the
    /// calendar so DST transitions do not shift the boundary.
    public static func query(_ range: AppleRelativeRange, now: Date, calendar: Calendar) -> AppleCalendarRangeQuery {
        let startOfToday = calendar.startOfDay(for: now)
        switch range {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
            return AppleCalendarRangeQuery(start: startOfToday, end: end, calendarID: nil)
        case .tomorrow:
            let start = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
            let end = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? start.addingTimeInterval(86_400)
            return AppleCalendarRangeQuery(start: start, end: end, calendarID: nil)
        case .next7Days:
            let end = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday.addingTimeInterval(604_800)
            return AppleCalendarRangeQuery(start: startOfToday, end: end, calendarID: nil)
        }
    }

    /// The default agenda window when no range is named: the next seven days,
    /// starting at the beginning of today.
    public static func defaultAgenda(now: Date, calendar: Calendar) -> AppleCalendarRangeQuery {
        query(.next7Days, now: now, calendar: calendar)
    }

    /// Spoken, time-zone-aware description of a range used to state exactly
    /// which interval was queried.
    public static func describe(_ query: AppleCalendarRangeQuery, calendar: Calendar) -> String {
        "\(AppleDateFormatting.spoken(query.start, calendar: calendar)) to \(AppleDateFormatting.spoken(query.end, calendar: calendar)) (\(calendar.timeZone.identifier))"
    }
}

// MARK: - Weather date resolution

/// Resolves a model-supplied date reference for weather forecasts. Accepts an
/// ISO date ("2026-10-24"), a weekday name ("Saturday", "saturday"), or a
/// relative phrase ("tomorrow"), or "now" for current conditions. Returns the day offset from today (0=today,
/// 1=tomorrow, etc.) and the total number of forecast days needed to include
/// that date (zero for "now"). Returns nil for unrecognized input or dates
/// outside today through seven days ahead.
public nonisolated enum AppleWeatherDateResolution {
    /// Weekday names mapped to Calendar's weekday index (1=Sunday, 2=Monday, ...).
    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    public nonisolated struct ResolvedDate: Equatable, Sendable {
        /// Day offset from today: 0=today, 1=tomorrow, etc.
        public var dayOffset: Int
        /// Total forecast days needed (including today) to cover the target date.
        public var daysNeeded: Int

        public init(dayOffset: Int, daysNeeded: Int) {
            self.dayOffset = dayOffset
            self.daysNeeded = daysNeeded
        }
    }

    /// Resolves a date reference to a day offset and required forecast days.
    /// - Parameters:
    ///   - text: The model-supplied date string (ISO date, weekday name, or "tomorrow").
    ///   - now: The current date/time.
    ///   - calendar: The device calendar for weekday computation.
    /// - Returns: A `ResolvedDate` with the offset and days needed, or nil if the input is unrecognized.
    public static func resolve(_ text: String?, now: Date, calendar: Calendar) -> ResolvedDate? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()

        if lowered == "now" {
            return ResolvedDate(dayOffset: 0, daysNeeded: 0)
        }

        // Relative phrase
        if lowered == "tomorrow" {
            return ResolvedDate(dayOffset: 1, daysNeeded: 2)
        }
        if lowered == "today" {
            return ResolvedDate(dayOffset: 0, daysNeeded: 1)
        }

        // ISO date (yyyy-MM-dd)
        if let parsed = AppleDateResolution.parse(raw, calendar: calendar) {
            let startOfToday = calendar.startOfDay(for: now)
            let startOfTarget = calendar.startOfDay(for: parsed.date)
            guard let dayDiff = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget).day, (0...7).contains(dayDiff) else {
                return nil // Outside the supported forecast window.
            }
            return ResolvedDate(dayOffset: dayDiff, daysNeeded: dayDiff + 1)
        }

        // Weekday name: find the next occurrence (including today if today matches)
        if let targetWeekday = weekdayNames[lowered] {
            let todayWeekday = calendar.component(.weekday, from: now)
            let offset = (targetWeekday - todayWeekday + 7) % 7
            // If the user says "Saturday" on a Saturday, they mean today (offset 0).
            // If they say "Saturday" on a Sunday, they mean 6 days from now.
            // The formula above already handles this: same weekday → offset 0.
            return ResolvedDate(dayOffset: offset, daysNeeded: offset + 1)
        }

        return nil
    }
}

// MARK: - Current time

/// The current-time tool's answer. The canonical ISO string and the localized
/// display are both computed from one execution-time instant.
public nonisolated enum AppleCurrentTime {
    public static func summarize(now: Date, calendar: Calendar) -> (summary: String, iso: String) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let spoken = formatter.string(from: now)
        let zone = calendar.timeZone.identifier
        let iso = AppleDateResolution.iso().string(from: now)
        return ("The current date and time is \(spoken) (\(zone), \(iso)).", iso)
    }
}

// MARK: - Map presentation

/// One place rendered on the inline map. Persisted with the tool payload so a
/// reopened conversation shows the exact real results without re-searching.
public nonisolated struct AppleMapResult: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    /// True for the device's own (approximate) current position.
    public var isCurrentPosition: Bool
    /// MapKit place identifier carried from the live search so a reopened
    /// conversation can fetch the native place details. Optional so stored
    /// payloads written before this field still decode.
    public var mapItemIdentifier: String?

    public init(id: String, name: String, address: String? = nil, latitude: Double, longitude: Double, isCurrentPosition: Bool, mapItemIdentifier: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.isCurrentPosition = isCurrentPosition
        self.mapItemIdentifier = mapItemIdentifier
    }

}

/// Structured, Codable map payload attached to a tool activity. The model's
/// prose is never parsed for coordinates; this is the authoritative result.
public nonisolated struct AppleMapPresentation: Codable, Equatable, Hashable, Sendable {
    public var results: [AppleMapResult]
    public var sourceTimestamp: Date
    /// Horizontal accuracy in meters when the marker is the device's position.
    public var accuracyMeters: Double?
    /// True when a coordinate was found but reverse geocoding failed, so the
    /// map is still shown with an honest "address unavailable" state.
    public var addressUnavailable: Bool

    public init(results: [AppleMapResult], sourceTimestamp: Date, accuracyMeters: Double? = nil, addressUnavailable: Bool) {
        self.results = results
        self.sourceTimestamp = sourceTimestamp
        self.accuracyMeters = accuracyMeters
        self.addressUnavailable = addressUnavailable
    }

}
