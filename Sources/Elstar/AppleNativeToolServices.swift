//
//  AppleNativeToolServices.swift
//  Elstar
//
//  Real on-device service implementations: EventKit reminders and calendar,
//  MapKit search and directions, CoreLocation one-shot location, and
//  WeatherKit current conditions and forecast.
//

import Foundation
import CoreLocation
import EventKit
import MapKit
import WeatherKit

// MARK: - Authorization mapping

#if canImport(EventKit)
func mapEventKitStatus(_ status: EKAuthorizationStatus) -> AppleNativeAuthorization {
    switch status {
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    case .denied: return .denied
    case .authorized: return .authorized
    case .fullAccess: return .authorized
    case .writeOnly: return .limited
    @unknown default: return .notDetermined
    }
}
#endif

// MARK: - Framework value handoff

/// Explicit @unchecked Sendable handoff for framework objects (EKReminder,
/// CLLocation) crossing a continuation boundary. The producing callback
/// resumes exactly once and the objects stay confined to their framework
/// stores' own locking, matching this file's @unchecked Sendable services.
struct AppleFrameworkValue<Value>: @unchecked Sendable {
    var value: Value
}

// MARK: - Reminders

public final class EventKitRemindersService: AppleRemindersService, @unchecked Sendable {

    public init() {}
    private let store = EKEventStore()

    public func authorizationStatus() async -> AppleNativeAuthorization {
        mapEventKitStatus(EKEventStore.authorizationStatus(for: .reminder))
    }

    public func requestFullAccess() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return }
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { throw AppleToolError.permissionDenied("Reminders") }
        } catch let error as AppleToolError {
            throw error
        } catch {
            throw AppleToolError.permissionDenied("Reminders")
        }
    }

    public func lists() async throws -> [AppleReminderListRecord] {
        try await ensureAccess()
        return store.calendars(for: .reminder).map { AppleReminderListRecord(id: $0.calendarIdentifier, title: $0.title) }
    }

    public func reminders(listID: String?, limit: Int) async throws -> [AppleReminderRecord] {
        try await ensureAccess()
        let calendars: [EKCalendar]? = resolveCalendar(listID).map { [$0] }
        let predicate = store.predicateForReminders(in: calendars)
        let fetched = try await fetchReminders(predicate)
        let open = fetched.filter { !$0.isCompleted }
        return open.sorted { lhs, rhs in
            (lhs.dueDateComponents?.date ?? .distantFuture) < (rhs.dueDateComponents?.date ?? .distantFuture)
        }
        .prefix(limit)
        .map(mapReminder)
    }

    public func reminder(id: String) async throws -> AppleReminderRecord? {
        try await ensureAccess()
        guard let reminder = await fetchReminder(id: id) else { return nil }
        return mapReminder(reminder)
    }

    // MARK: Helpers

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return
        case .restricted:
            throw AppleToolError.permissionRestricted("Reminders")
        case .denied:
            throw AppleToolError.permissionDenied("Reminders")
        default:
            try await requestFullAccess()
        }
    }

    private func resolveCalendar(_ idOrName: String?) -> EKCalendar? {
        guard let idOrName, !idOrName.isEmpty else { return nil }
        let calendars = store.calendars(for: .reminder)
        if let byID = calendars.first(where: { $0.calendarIdentifier == idOrName }) { return byID }
        return calendars.first { $0.title.localizedCaseInsensitiveContains(idOrName) }
    }

    private func fetchReminder(id: String) async -> EKReminder? {
        if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
            return reminder
        }
        // A calendar item identifier can differ across stores; fall back to a
        // bounded scan of the person's reminder lists. Fully async so it never
        // blocks the cooperative pool waiting on a callback.
        for calendar in store.calendars(for: .reminder) {
            let predicate = store.predicateForReminders(in: [calendar])
            let reminders = (try? await fetchReminders(predicate)) ?? []
            if let found = reminders.first(where: { $0.calendarItemIdentifier == id }) { return found }
        }
        return nil
    }

    private func fetchReminders(_ predicate: NSPredicate) async throws -> [EKReminder] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppleFrameworkValue<[EKReminder]>, Error>) in
            let guardState = AppleSingleResumeGuard()
            store.fetchReminders(matching: predicate) { reminders in
                guard guardState.claim() else { return }
                continuation.resume(returning: AppleFrameworkValue(value: reminders ?? []))
            }
        }.value
    }

    private func mapReminder(_ reminder: EKReminder) -> AppleReminderRecord {
        AppleReminderRecord(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Reminder",
            due: reminder.dueDateComponents?.date,
            hasAlert: reminder.alarms?.isEmpty == false,
            listID: reminder.calendar?.calendarIdentifier,
            listTitle: reminder.calendar?.title,
            isCompleted: reminder.isCompleted
        )
    }
}

// MARK: - Calendar

public final class EventKitCalendarService: AppleCalendarService, @unchecked Sendable {

    public init() {}
    private let store = EKEventStore()

    public func authorizationStatus() async -> AppleNativeAuthorization {
        mapEventKitStatus(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestFullAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw AppleToolError.permissionDenied("Calendar") }
        } catch let error as AppleToolError {
            throw error
        } catch {
            throw AppleToolError.permissionDenied("Calendar")
        }
    }

    public func events(in query: AppleCalendarRangeQuery, limit: Int) async throws -> [AppleCalendarEventRecord] {
        try await ensureAccess()
        guard query.end >= query.start else { throw AppleToolError.invalidInput("The end time must not be before the start time.") }
        let calendars = query.calendarID.flatMap { id in store.calendars(for: .event).first { $0.calendarIdentifier == id } }.map { [$0] }
        let predicate = store.predicateForEvents(withStart: query.start, end: query.end, calendars: calendars)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map(mapEvent)
    }

    public func event(id: String) async throws -> AppleCalendarEventRecord? {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: id) else { return nil }
        return mapEvent(event)
    }

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return
        case .restricted:
            throw AppleToolError.permissionRestricted("Calendar")
        case .denied:
            throw AppleToolError.permissionDenied("Calendar")
        default:
            try await requestFullAccess()
        }
    }

    private func mapEvent(_ event: EKEvent) -> AppleCalendarEventRecord {
        AppleCalendarEventRecord(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            calendarID: event.calendar?.calendarIdentifier,
            calendarTitle: event.calendar?.title,
            isWritable: event.calendar?.allowsContentModifications ?? true
        )
    }
}

// MARK: - Location

/// One-shot when-in-use location. Requests authorization only when a
/// `.currentLocation` anchor is used, and fails honestly when denied. A
/// location request is issued only after the delegate reports an authorized
/// status (Apple's documented flow); a bounded timeout guarantees the turn can
/// never hang, and every resume path is single-shot.
public final class OneShotLocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    public override init() {}
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppleFrameworkValue<CLLocation>, Error>?
    private var timeoutTask: Task<Void, Never>?

    private static let timeout: Duration = .seconds(15)
    private static let permissionPromptTimeout: Duration = .seconds(30)
    /// Last-known location is good enough to anchor weather or a place; older
    /// fixes are ignored so "where am I" never answers with yesterday's spot.
    private static let cachedMaxAge: TimeInterval = 6 * 3600
    private var restartedForPermission = false

    public func authorizationStatus() -> AppleNativeAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        @unknown default: return .notDetermined
        }
    }

    public func currentLocation() async throws -> CLLocation {
        let status = manager.authorizationStatus
        if status == .denied { throw AppleToolError.permissionDenied("Location") }
        if status == .restricted { throw AppleToolError.permissionRestricted("Location") }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppleFrameworkValue<CLLocation>, Error>) in
            armTimeout(Self.timeout)
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            switch status {
            case .notDetermined:
                // Wait for `locationManagerDidChangeAuthorization` before
                // issuing the request.
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                resume(throwing: AppleToolError.permissionDenied("Location"))
            }
        }.value
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if hasPendingContinuation() {
                manager.requestLocation()
            }
        case .denied:
            resume(throwing: AppleToolError.permissionDenied("Location"))
        case .restricted:
            resume(throwing: AppleToolError.permissionRestricted("Location"))
        default:
            break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            resume(throwing: AppleToolError.network("Your location couldn't be determined."))
            return
        }
        resume(returning: location)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                resume(throwing: AppleToolError.permissionDenied("Location"))
                return
            case .locationUnknown:
                // Transient: keep waiting; the timeout falls back to the
                // last-known location.
                return
            default:
                break
            }
        }
        if let cached = cachedLocation() {
            resume(returning: cached)
            return
        }
        resume(throwing: AppleToolError.network("Your location couldn't be determined."))
    }

    private func hasPendingContinuation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation != nil
    }

    private func cachedLocation() -> CLLocation? {
        guard let location = manager.location,
              abs(location.timestamp.timeIntervalSinceNow) <= Self.cachedMaxAge else { return nil }
        return location
    }

    /// The timeout no longer abandons a pending request while the system
    /// permission dialog is still open, and prefers the system's last-known
    /// location over an honest-but-useless timeout error.
    private func handleTimeout(after duration: Duration) {
        if let cached = cachedLocation() {
            resume(returning: cached)
            return
        }
        lock.lock()
        let pending = continuation != nil
        let canRestart = pending && !restartedForPermission && manager.authorizationStatus == .notDetermined
        if canRestart { restartedForPermission = true }
        lock.unlock()
        guard pending else { return }
        if canRestart {
            armTimeout(Self.permissionPromptTimeout)
        } else {
            resume(throwing: AppleToolError.network("Your location couldn't be determined in time."))
        }
    }

    private func armTimeout(_ duration: Duration) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.handleTimeout(after: duration)
        }
        lock.lock()
        self.timeoutTask = task
        lock.unlock()
    }

    private func resume(returning location: CLLocation) {
        lock.lock()
        let continuation = self.continuation
        let timeout = timeoutTask
        self.continuation = nil
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(returning: AppleFrameworkValue(value: location))
    }

    private func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        let timeout = timeoutTask
        self.continuation = nil
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(throwing: error)
    }
}

// MARK: - Places

public final class MapKitPlacesService: ApplePlacesService, @unchecked Sendable {

    public init() {}
    private let locationProvider = OneShotLocationProvider()
    private let geocoder = CLGeocoder()

    public func locationAuthorizationStatus() async -> AppleNativeAuthorization {
        locationProvider.authorizationStatus()
    }

    public func search(_ request: AppleNearbyPlacesRequest) async throws -> [ApplePlaceRecord] {
        var region: MKCoordinateRegion?
        var query = request.query
        switch request.anchor {
        case .currentLocation:
            let location = try await locationProvider.currentLocation()
            region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
        case .named(let place):
            query = "\(request.query) near \(place)"
        case .coordinate(let latitude, let longitude):
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: 8_000,
                longitudinalMeters: 8_000
            )
        }
        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = query
        if let region { searchRequest.region = region }
        let response = try await startSearch(searchRequest)
        let origin = try? await currentLocationIfAuthorized()
        return response.mapItems.prefix(request.limit).map { item in
            let coordinate = item.placemark.coordinate
            let distance = origin.map { CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: $0) }
            return ApplePlaceRecord(
                id: "\(item.name ?? "place")|\(coordinate.latitude),\(coordinate.longitude)",
                name: item.name ?? "Place",
                address: formattedAddress(item.placemark),
                distanceMeters: distance,
                website: item.url,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    /// The device's own current place. Resolves a real CLLocation first, so a
    /// missing address never prevents the coordinate from being shown. Never a
    /// text search.
    public func currentPlace(_ request: AppleCurrentPlaceRequest) async throws -> ApplePlaceRecord {
        let status = locationProvider.authorizationStatus()
        if status == .denied { throw AppleToolError.permissionDenied("Location") }
        if status == .restricted { throw AppleToolError.permissionRestricted("Location") }
        let location: CLLocation
        do {
            location = try await locationProvider.currentLocation()
        } catch let error as AppleToolError {
            throw error
        } catch {
            throw AppleToolError.network("Your location couldn't be determined right now.")
        }
        let coordinate = location.coordinate
        var address: String?
        var addressUnavailable = false
        if request.reverseGeocode {
            if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
                address = Self.formattedAddress(placemark)
            }
            if address == nil { addressUnavailable = true }
        }
        return ApplePlaceRecord(
            id: "current|\(coordinate.latitude),\(coordinate.longitude)",
            name: "Current location",
            address: address,
            distanceMeters: 0,
            website: nil,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            isCurrentPosition: true,
            accuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            addressUnavailable: addressUnavailable
        )
    }

    // MARK: Helpers

    private func startSearch(_ request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
        do {
            return try await MKLocalSearch(request: request).start()
        } catch let error as AppleToolError {
            throw error
        } catch {
            throw Self.friendlyMapError(error, for: request.naturalLanguageQuery)
        }
    }

    /// Maps a raw MapKit/CoreLocation error to honest, friendly copy. No raw
    /// framework domain string ever reaches the person.
    public static func friendlyMapError(_ error: Error, for query: String?) -> AppleToolError {
        let nsError = error as NSError
        if nsError.domain == MKErrorDomain {
            switch MKError.Code(rawValue: UInt(nsError.code)) {
            case .placemarkNotFound:
                return .notFound("I couldn't find \"\(query ?? "that place")\".")
            case .directionsNotFound:
                return .notFound("I couldn't find a route to \"\(query ?? "that place")\".")
            case .loadingThrottled, .serverFailure:
                return .network("The place lookup service is busy right now. Try again in a moment.")
            case .decodingFailed:
                return .network("The place lookup returned something unexpected. Try again.")
            default:
                return .network("The place lookup failed. Try again.")
            }
        }
        if (error as? CLError)?.code == .denied {
            return .permissionDenied("Location")
        }
        if error is CLError {
            return .network("Your location couldn't be determined right now.")
        }
        return .network("The place lookup failed. Try again.")
    }

    private func currentLocationIfAuthorized() async throws -> CLLocation? {
        guard locationProvider.authorizationStatus() == .authorized else { return nil }
        return try? await locationProvider.currentLocation()
    }

    private func formattedAddress(_ placemark: MKPlacemark) -> String? {
        Self.formattedAddress(placemark)
    }

    private static func formattedAddress(_ placemark: CLPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [placemark.locality, placemark.administrativeArea].compactMap { $0 }
        let parts = ([street].filter { !$0.isEmpty } + city).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Weather

public final class WeatherKitWeatherService: AppleWeatherService, @unchecked Sendable {

    public init() {}
    private let service = WeatherService.shared
    private let geocoder = CLGeocoder()

    public func isAvailable() -> Bool {
        // WeatherKit is entitlement-gated; availability is confirmed at fetch
        // time by catching the framework's errors.
        true
    }

    public func weather(for request: AppleWeatherRequest) async throws -> AppleWeatherSnapshot {
        let location = try await resolveLocation(request.anchor)
        do {
            return try await fetchWeather(location: location, request: request)
        } catch let error as AppleToolError {
            throw error
        } catch {
            // One bounded immediate retry: the weather daemon's JWT auth can
            // fail transiently right after install or unlock. The read has no
            // side effects and the final error stays honest.
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { throw AppleToolError.cancelled }
            do {
                return try await fetchWeather(location: location, request: request)
            } catch let error as AppleToolError {
                throw error
            } catch {
                throw AppleToolError.notAvailable("Weather isn't available right now - WeatherKit said: \(Self.boundedCause(error))")
            }
        }
    }

    /// Bounded single-line underlying cause so a WeatherKit failure stays
    /// diagnosable in chat and exports without multi-line framework spam.
    private static func boundedCause(_ error: Error) -> String {
        let text = String(describing: error).replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(200))
    }

    private func fetchWeather(location: CLLocation, request: AppleWeatherRequest) async throws -> AppleWeatherSnapshot {
        let current = try await service.weather(for: location, including: .current)
        var isHourly = false
        if case .hourly = request.kind { isHourly = true }
        let daily = isHourly ? nil : (try? await service.weather(for: location, including: .daily))
        let hourlyForecast = isHourly ? (try? await service.weather(for: location, including: .hourly)) : nil
        let attribution = try? await service.attribution
        let temperatureC = current.temperature.converted(to: .celsius).value
        var forecast: [AppleWeatherDay] = []
        if case .forecast(let days) = request.kind, let daily {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM"
            let calendar = Calendar.current
            forecast = daily.forecast.prefix(days).map { day -> AppleWeatherDay in
                var label = formatter.string(from: day.date)
                if calendar.isDateInToday(day.date) {
                    label = "Today " + label
                } else if calendar.isDateInTomorrow(day.date) {
                    label = "Tomorrow " + label
                }
                return AppleWeatherDay(
                    day: label,
                    condition: day.condition.description,
                    highCelsius: day.highTemperature.converted(to: .celsius).value,
                    lowCelsius: day.lowTemperature.converted(to: .celsius).value
                )
            }
        }
        var hourly: [AppleWeatherHour] = []
        if case .hourly(let requestedHours) = request.kind, let hourlyForecast {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE HH:mm"
            hourly = hourlyForecast.prefix(min(max(requestedHours, 1), 24)).map { hour in
                AppleWeatherHour(
                    time: formatter.string(from: hour.date),
                    condition: hour.condition.description,
                    temperatureCelsius: hour.temperature.converted(to: .celsius).value,
                    precipitationChance: hour.precipitationChance
                )
            }
        }
        let name = (try? await reverseGeocode(location)) ?? "Your location"
        return AppleWeatherSnapshot(
            locationName: name,
            condition: current.condition.description,
            temperatureCelsius: temperatureC,
            highCelsius: daily?.forecast.first.map { $0.highTemperature.converted(to: .celsius).value },
            lowCelsius: daily?.forecast.first.map { $0.lowTemperature.converted(to: .celsius).value },
            forecast: forecast,
            attributionText: attribution?.legalAttributionText ?? "Weather data provided by Apple Weather.",
            attributionURL: attribution?.legalPageURL,
            attributionImageURL: attribution?.combinedMarkDarkURL,
            hourly: hourly
        )
    }

    private func resolveLocation(_ anchor: ApplePlaceAnchor) async throws -> CLLocation {
        switch anchor {
        case .coordinate(let latitude, let longitude):
            return CLLocation(latitude: latitude, longitude: longitude)
        case .currentLocation:
            return try await OneShotLocationProvider().currentLocation()
        case .named(let name):
            let placemarks = try await geocoder.geocodeAddressString(name)
            guard let location = placemarks.first?.location else {
                throw AppleToolError.notFound("I couldn't find \"\(name)\".")
            }
            return location
        }
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> String? {
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        return placemarks.first?.locality
    }
}