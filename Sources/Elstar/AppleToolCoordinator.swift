import Foundation

/// Runs one model-decided tool operation to completion: validates it, asks for
/// an explicit per-action confirmation when it mutates state, serializes the
/// work, records a durable receipt, and reports running/completed/failed as
/// stable tool-card events. One executor exists per live turn, so duplicate
/// calls within a turn never repeat a side effect.
public nonisolated final class AppleToolExecutor: AppleToolDispatching, @unchecked Sendable {
    private let key: HarnessConversationKey
    private let messageID: String
    private let tracker: any HarnessActiveOperationTracking
    private let sink: any HarnessToolEventSink
    private let serializer: AppleOperationSerializer
    private let confirmations: AppleConfirmationStore
    private let journal: AppleToolJournal
    private let services: AppleToolServices
    private let clock: any AppleClock
    private let calendar: Calendar
#if DEBUG
    private let developerRecorder: (any HarnessDiagnosticRecording)?
#endif

    private let lock = NSLock()
    /// Results for mutating operations, keyed by signature. Failed and
    /// uncertain mutations are cached too, so a possibly-committed write is
    /// never repeated within the turn. Reads are intentionally never cached:
    /// a fresh read (the clock, the agenda after a write) must see new state.
    private var performed: [String: AppleToolResult] = [:]

    public init(
        key: HarnessConversationKey,
        messageID: String,
        tracker: any HarnessActiveOperationTracking,
        sink: any HarnessToolEventSink,
        serializer: AppleOperationSerializer,
        confirmations: AppleConfirmationStore,
        journal: AppleToolJournal,
        services: AppleToolServices,
        clock: any AppleClock = SystemAppleClock(),
        calendar: Calendar = .current
    ) {
        self.key = key
        self.messageID = messageID
        self.tracker = tracker
        self.sink = sink
        self.serializer = serializer
        self.confirmations = confirmations
        self.journal = journal
        self.services = services
        self.clock = clock
        self.calendar = calendar
#if DEBUG
        self.developerRecorder = nil
#endif
    }

#if DEBUG
    /// Development-only copy that attaches an explicit recording sink. The
    /// backend already holds the exact conversation key, so attribution never
    /// relies on a global "last selected chat".
    public func settingDeveloperRecorder(_ recorder: (any HarnessDiagnosticRecording)?) -> AppleToolExecutor {
        let copy = AppleToolExecutor(key: key, messageID: messageID, tracker: tracker, sink: sink, serializer: serializer, confirmations: confirmations, journal: journal, services: services, clock: clock, calendar: calendar, developerRecorder: recorder)
        return copy
    }

    private init(
        key: HarnessConversationKey,
        messageID: String,
        tracker: any HarnessActiveOperationTracking,
        sink: any HarnessToolEventSink,
        serializer: AppleOperationSerializer,
        confirmations: AppleConfirmationStore,
        journal: AppleToolJournal,
        services: AppleToolServices,
        clock: any AppleClock,
        calendar: Calendar,
        developerRecorder: (any HarnessDiagnosticRecording)?
    ) {
        self.key = key
        self.messageID = messageID
        self.tracker = tracker
        self.sink = sink
        self.serializer = serializer
        self.confirmations = confirmations
        self.journal = journal
        self.services = services
        self.clock = clock
        self.calendar = calendar
        self.developerRecorder = developerRecorder
    }
#endif

    public func perform(_ request: AppleToolRequest) async -> AppleToolResult? {
        let signature = request.signature
        if request.isMutation, let cached = cachedResult(for: signature) { return cached }

        let operationID = UUID().uuidString
        let toolName = request.toolName
#if DEBUG
        developerRecorder?.recordToolCall(turnID: messageID, callID: operationID, operation: request.operation.rawValue, structured: DeveloperChatToolArguments.describe(request), conversationKey: key.absoluteKey)
#endif
        emit(.running, operationID: operationID, name: toolName, detail: request.activityDetail)

        if request.isMutation {
            let allowed = await requestConfirmation(request, operationID: operationID)
            guard allowed else {
#if DEBUG
                developerRecorder?.recordToolResult(turnID: messageID, callID: operationID, operation: request.operation.rawValue, status: "declined", summary: "The person declined this action.", structured: nil, conversationKey: key.absoluteKey)
#endif
                emit(.failed, operationID: operationID, name: toolName, detail: "Declined", output: "The person declined this action.")
                return nil
            }
        }

        do {
            let result = try await serializer.run { [self] in
                try await execute(request, operationID: operationID)
            }
            if let receipt = result.receipt {
                await journal.record(receipt)
                sink.actionReceipt(key, receipt)
            }
            if request.isMutation { storeResult(result, for: signature) }
#if DEBUG
            developerRecorder?.recordToolResult(turnID: messageID, callID: operationID, operation: request.operation.rawValue, status: result.status.rawValue, summary: result.summary, structured: DeveloperChatToolArguments.result(result), conversationKey: key.absoluteKey)
#endif
            emit(.completed, operationID: operationID, name: toolName, detail: result.items.first?.subtitle, output: result.modelText, map: result.mapPresentation, directions: result.directionsPresentation, weather: result.weatherPresentation, photos: result.photosPresentation)
            return result
        } catch let error as AppleToolError {
            let status = request.operation == .calculate ? AppleToolStatus.failed : AppleToolStatus(error: error)
            let result = AppleToolResult(summary: Self.recoveryText(for: error), status: status)
            if request.isMutation {
                // A possibly-committed write is sticky: record it both in the
                // journal and in the within-turn cache so it is never retried.
                let receipt = AppleToolReceipt(
                    operationID: operationID,
                    family: request.family,
                    action: request.toolName,
                    nativeID: nil,
                    summary: error.userMessage,
                    recordedAt: clock.now(),
                    detail: nil,
                    status: status == .uncertain ? .uncertain : .failed,
                    conversationID: key.conversationID,
                    assistantMessageID: messageID
                )
                await journal.record(receipt)
                sink.actionReceipt(key, receipt)
                storeResult(result, for: signature)
            }
#if DEBUG
            developerRecorder?.recordToolResult(turnID: messageID, callID: operationID, operation: request.operation.rawValue, status: status.rawValue, summary: error.userMessage, structured: nil, conversationKey: key.absoluteKey)
#endif
            emit(.failed, operationID: operationID, name: toolName, detail: nil, output: error.userMessage)
            return result
        } catch {
#if DEBUG
            developerRecorder?.recordToolResult(turnID: messageID, callID: operationID, operation: request.operation.rawValue, status: "failed", summary: error.localizedDescription, structured: nil, conversationKey: key.absoluteKey)
#endif
            emit(.failed, operationID: operationID, name: toolName, detail: nil, output: error.localizedDescription)
            return AppleToolResult(summary: "The action could not be completed: \(error.localizedDescription)", status: .failed)
        }
    }

    /// Actionable recovery guidance fed back to the model instead of ending the
    /// whole turn with a generic refusal.
    public static func recoveryText(for error: AppleToolError) -> String {
        switch error {
        case .permissionDenied, .permissionRestricted, .serviceDisabled:
            return "Action needed: \(error.userMessage) Tell the person what to enable, then retry only if they ask."
        case .invalidInput(let detail), .notFound(let detail):
            return "I need different information: \(detail)"
        case .network(let detail):
            return "A read failed: \(detail) You may try a bounded alternative, but do not claim success."
        case .unsupportedFormat(let detail):
            return "That format isn't supported: \(detail)"
        case .blocked(let detail):
            return "That destination is not allowed: \(detail)"
        case .cancelled:
            return "The action was cancelled; nothing changed."
        case .uncertain(let detail):
            return "The outcome is uncertain: \(detail) Do not retry automatically; tell the person and let them decide."
        case .notAvailable(let detail):
            return "Not possible right now: \(detail)"
        }
    }

    // MARK: - Confirmation

    private func requestConfirmation(_ request: AppleToolRequest, operationID: String) async -> Bool {
        tracker.recordActiveKey(operationID, key: key)
        let detail = await confirmationDetail(for: request)
        let interaction = sink.confirmationInteraction(id: operationID, request: request, detailOverride: detail)
        sink.interactionRequested(key, interaction)
#if DEBUG
        developerRecorder?.recordConfirmationRequested(turnID: messageID, callID: operationID, operation: request.operation.rawValue, detail: detail ?? request.confirmationTitle, conversationKey: key.absoluteKey)
#endif
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                confirmations.insert(operationID, continuation)
                // If the task was cancelled before the handler could see the
                // pending entry (or is already cancelled on entry), resolve
                // here as declined; the resolve is idempotent.
                if Task.isCancelled {
                    confirmations.resolve(operationID, allowed: false)
                }
            }
        } onCancel: {
            confirmations.resolve(operationID, allowed: false)
        }
        tracker.clearActiveKey(operationID)
        sink.interactionResolved(key, requestID: operationID)
#if DEBUG
        developerRecorder?.recordConfirmationResolved(turnID: messageID, callID: operationID, allowed: allowed, conversationKey: key.absoluteKey)
#endif
        return allowed
    }

    /// Exact preview shown before a mutation runs.
    private func confirmationDetail(for request: AppleToolRequest) async -> String? {
        request.confirmationDetail
    }

    private func cachedResult(for signature: String) -> AppleToolResult? {
        lock.lock(); defer { lock.unlock() }
        return performed[signature]
    }

    private func storeResult(_ result: AppleToolResult, for signature: String) {
        lock.lock(); performed[signature] = result; lock.unlock()
    }

    // MARK: - Execution

    private func execute(_ request: AppleToolRequest, operationID: String) async throws -> AppleToolResult {
        switch request {
        case .listReminderLists:
            let lists = try await services.reminders.lists()
            return AppleToolResult(
                summary: "Reminder lists: \(lists.count).",
                items: lists.prefix(12).map { AppleToolDisplayItem(title: $0.title, subtitle: nil, reference: $0.id) }
            )

        case .listReminders(let listID):
            let reminders = try await services.reminders.reminders(listID: listID, limit: 25)
            return AppleToolResult(
                summary: reminders.isEmpty ? "No reminders found." : "Found \(reminders.count) reminders.",
                items: reminders.map { reminder in
                    AppleToolDisplayItem(
                        title: reminder.title,
                        subtitle: reminder.due.map { reminder.isCompleted ? "completed" : AppleDateFormatting.spoken($0) },
                        reference: reminder.id
                    )
                }
            )

        case .listCalendarEvents(let query):
            let events = try await services.calendar.events(in: query, limit: 40)
            let interval = AppleDateResolution.describe(query, calendar: calendar)
            return AppleToolResult(
                summary: events.isEmpty
                    ? "No events found between \(interval)."
                    : "\(events.count) event\(events.count == 1 ? "" : "s") between \(interval):",
                items: events.map { event -> AppleToolDisplayItem in
                    // Model-facing context so questions like "where?" are
                    // answerable from one read: location plus calendar name.
                    let detail = [event.location, event.calendarTitle]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    return AppleToolDisplayItem(
                        title: event.title,
                        subtitle: event.isAllDay ? "\(AppleDateFormatting.spokenDay(event.start, calendar: calendar)) - All day" : AppleDateFormatting.spoken(event.start),
                        detail: detail.isEmpty ? nil : detail,
                        reference: event.id
                    )
                }
            )

        case .calendarAvailability(let query):
            let events = try await services.calendar.events(in: query, limit: 40)
            let busy = events.filter { !$0.isAllDay }
            let interval = AppleDateResolution.describe(query, calendar: calendar)
            return AppleToolResult(
                summary: busy.isEmpty ? "No timed conflicts between \(interval)." : "\(busy.count) busy blocks between \(interval):",
                items: busy.map { AppleToolDisplayItem(title: $0.title, subtitle: "\(AppleDateFormatting.spoken($0.start)) to \(AppleDateFormatting.spoken($0.end))", reference: $0.id) }
            )

        case .searchNearbyPlaces(let searchRequest):
            let places = try await services.places.search(searchRequest)
            let map = Self.mapPresentation(for: places, timestamp: clock.now())
            return AppleToolResult(
                summary: places.isEmpty ? "No places found." : "Found \(places.count) places.",
                items: places.map { place in
                    AppleToolDisplayItem(
                        title: place.name,
                        subtitle: place.address ?? place.distanceMeters.map { "\(Int($0)) m away" },
                        reference: place.id
                    )
                },
                mapPresentation: map
            )

        case .currentPlace(let currentRequest):
            let place = try await services.places.currentPlace(currentRequest)
            let map = Self.mapPresentation(for: [place], timestamp: clock.now())
            let accuracy = place.accuracyMeters.map { " within about \(Int($0)) m" } ?? ""
            let summary: String
            if let address = place.address, !address.isEmpty {
                summary = "You're near \(address)\(accuracy)."
            } else {
                summary = "You're at \(String(format: "%.4f", place.latitude)), \(String(format: "%.4f", place.longitude))\(accuracy). The street address isn't available right now."
            }
            return AppleToolResult(
                summary: summary,
                items: [AppleToolDisplayItem(title: place.address ?? "Current location", subtitle: place.address == nil ? "address unavailable" : nil, reference: place.id)],
                mapPresentation: map
            )

        case .directions(let directionsRequest):
            return AppleToolResult(
                summary: "Ready to open directions to \"\(directionsRequest.destinationName)\". Choose a map app.",
                items: [AppleToolDisplayItem(title: directionsRequest.destinationName, subtitle: directionsRequest.destinationAddress, reference: directionsRequest.destinationID)],
                directionsPresentation: AppleDirectionsPresentation(
                    destinationID: directionsRequest.destinationID,
                    destinationName: directionsRequest.destinationName,
                    destinationAddress: directionsRequest.destinationAddress,
                    mode: directionsRequest.mode
                )
            )

        case .findPhotos(let query):
            let presentation = try await services.photos.find(query)
            let count = presentation.photos.count
            var summary = count == 0 ? "No matching photos were found in the accessible library." : "Found \(count) matching \(count == 1 ? "photo" : "photos"), newest first."
            if presentation.limitedAccess { summary += " Access is limited to the photos you selected." }
            if presentation.hasMore { summary += " More matches are available; narrow the date range or album." }
            let items = presentation.photos.map { photo in
                AppleToolDisplayItem(title: photo.isScreenshot ? "Screenshot" : "Photo", subtitle: photo.creationDate.map { AppleDateFormatting.spoken($0, calendar: calendar) }, detail: "\(photo.pixelWidth) x \(photo.pixelHeight)\(photo.isFavorite ? ", favorite" : "")")
            }
            return AppleToolResult(summary: summary, items: items, photosPresentation: presentation)
        case .calculate(let expression):
            let calculation = try AppleCalculator.evaluate(expression)
            let suffix = calculation.isApproximate ? " (approximate - decimal precision limit)" : ""
            return AppleToolResult(summary: "\(calculation.expression) = \(calculation.value)" + suffix)

        case .currentTime:
            let instant = clock.now()
            let summary = AppleCurrentTime.summarize(now: instant, calendar: calendar)
            return AppleToolResult(
                summary: summary.summary,
                items: [AppleToolDisplayItem(title: AppleDateFormatting.spoken(instant, calendar: calendar), subtitle: calendar.timeZone.identifier, reference: nil)]
            )

        case .weather(let weatherRequest):
            let snapshot = try await services.weather.weather(for: weatherRequest)
            var summary = "\(snapshot.locationName): \(snapshot.condition), \(Int(snapshot.temperatureCelsius.rounded()))°C"
            if let high = snapshot.highCelsius, let low = snapshot.lowCelsius {
                summary += " (H \(Int(high.rounded()))° L \(Int(low.rounded()))°)"
            }
            if !snapshot.hourly.isEmpty {
                let hourLines = snapshot.hourly.map { hour in
                    "\(hour.time) \(hour.condition) \(Int(hour.temperatureCelsius.rounded()))° \(Int((hour.precipitationChance * 100).rounded()))% rain"
                }.joined(separator: "; ")
                summary += ". Hourly: \(hourLines)"
            }
            summary += ". Weather data by Apple Weather."
            var items = [AppleToolDisplayItem(title: snapshot.condition, subtitle: "\(Int(snapshot.temperatureCelsius.rounded()))°C", reference: nil)]
            for hour in snapshot.hourly {
                items.append(AppleToolDisplayItem(title: hour.time, subtitle: "\(hour.condition) \(Int(hour.temperatureCelsius.rounded()))°, \(Int((hour.precipitationChance * 100).rounded()))% rain", reference: nil))
            }
            for day in snapshot.forecast {
                items.append(AppleToolDisplayItem(title: day.day, subtitle: "\(day.condition) \(Int(day.highCelsius.rounded()))° / \(Int(day.lowCelsius.rounded()))°", reference: nil))
            }
            // The highlight is matched by real calendar day in the location's
            // timezone, never by array index, and only when that day actually
            // exists in the fetched forecast.
            var highlightedDate: Date?
            if let offset = weatherRequest.highlightDay, (1...4).contains(offset) {
                var dayCalendar = Calendar(identifier: .gregorian)
                if let timeZoneID = snapshot.timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneID) {
                    dayCalendar.timeZone = timeZone
                } else {
                    dayCalendar.timeZone = .current
                }
                let reference = snapshot.observedAt ?? clock.now()
                if let target = dayCalendar.date(byAdding: .day, value: offset, to: reference) {
                    highlightedDate = snapshot.forecast.first(where: { day in
                        guard let date = day.date else { return false }
                        return dayCalendar.isDate(date, inSameDayAs: target)
                    })?.date
                }
            }
            return AppleToolResult(summary: summary, items: items, weatherPresentation: AppleWeatherPresentation(locationName: snapshot.locationName, attributionText: snapshot.attributionText, attributionURL: snapshot.attributionURL, attributionImageURL: snapshot.attributionImageURL, condition: snapshot.condition, temperatureCelsius: snapshot.temperatureCelsius, highCelsius: snapshot.highCelsius, lowCelsius: snapshot.lowCelsius, symbolName: snapshot.symbolName, isDaylight: snapshot.isDaylight, observedAt: snapshot.observedAt, timeZoneIdentifier: snapshot.timeZoneIdentifier, forecast: snapshot.forecast, highlightedDate: highlightedDate))

        case .fetchWebPage(let fetchRequest):
            let page = try await services.webFetch.fetch(fetchRequest)
            var items = page.links.prefix(12).map { AppleToolDisplayItem(title: $0.text, subtitle: $0.url.absoluteString, reference: $0.url.absoluteString) }
            if items.isEmpty { items = [AppleToolDisplayItem(title: page.sourceURL.absoluteString, subtitle: "source", reference: page.sourceURL.absoluteString)] }
            let titleLine = page.title.map { "\($0)\n" } ?? ""
            return AppleToolResult(summary: "Fetched \(page.sourceURL.absoluteString).\n\(titleLine)\(page.text)", items: items)
        }
    }

    public static func datesMatch(_ lhs: Date?, _ rhs: Date?, tolerance: TimeInterval) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let l?, let r?): return abs(l.timeIntervalSince(r)) <= tolerance
        default: return false
        }
    }

    /// Builds the persisted map payload from real place records.
    public static func mapPresentation(for places: [ApplePlaceRecord], timestamp: Date) -> AppleMapPresentation? {
        guard !places.isEmpty else { return nil }
        let results = places.prefix(12).map { place in
            AppleMapResult(
                id: place.id,
                name: place.name,
                address: place.address,
                latitude: place.latitude,
                longitude: place.longitude,
                isCurrentPosition: place.isCurrentPosition,
                mapItemIdentifier: place.mapItemIdentifier
            )
        }
        let accuracy = places.first(where: { $0.isCurrentPosition })?.accuracyMeters
        let addressUnavailable = places.contains { $0.addressUnavailable }
        return AppleMapPresentation(results: results, sourceTimestamp: timestamp, accuracyMeters: accuracy, addressUnavailable: addressUnavailable)
    }

    private func emit(_ status: ToolActivity.Status, operationID: String, name: String, detail: String?, output: String? = nil, map: AppleMapPresentation? = nil, directions: AppleDirectionsPresentation? = nil, weather: AppleWeatherPresentation? = nil, photos: ApplePhotosPresentation? = nil) {
        sink.toolDelta(key, messageID: messageID, part: ToolActivity(
            id: operationID,
            name: name,
            status: status,
            detail: detail,
            outputExcerpt: output.map { String($0.prefix(1_200)) },
            startedAt: clock.now(),
            mapPresentation: map,
            directionsPresentation: directions,
            weatherPresentation: weather,
            photosPresentation: photos
        ))
    }
}

// MARK: - Request naming

nonisolated extension AppleToolStatus {
    /// Maps a typed tool failure to the structured outcome status the model
    /// sees, so it can recover (ask the person) instead of ending the turn.
    public init(error: AppleToolError) {
        switch error {
        case .permissionDenied, .permissionRestricted, .serviceDisabled, .invalidInput, .notFound, .notAvailable, .unsupportedFormat, .blocked:
            self = .needsUserAction
        case .uncertain:
            self = .uncertain
        case .cancelled, .network:
            self = .failed
        }
    }
}

nonisolated extension AppleToolRequest {
    public var toolName: String {
        switch self {
        case .listReminderLists: "List reminder lists"
        case .listReminders: "List reminders"
        case .listCalendarEvents: "List calendar events"
        case .calendarAvailability: "Check availability"
        case .searchNearbyPlaces: "Find nearby places"
        case .directions: "Directions"
        case .weather: "Get weather"
        case .fetchWebPage: "Read web page"
        case .currentTime: "Get current time"
        case .calculate: "Calculate"
        case .findPhotos: "Find photos"
        case .currentPlace: "Find current place"
        }
    }

    public var activityDetail: String? {
        switch self {
        case .searchNearbyPlaces(let r): r.query
        case .calculate(let expression): String(expression.prefix(512))
        case .fetchWebPage(let r): r.url.host(percentEncoded: false)
        case .weather(let r): r.anchor.key
        default: nil
        }
    }

    /// Stable identity for within-turn duplicate suppression.
    public var signature: String { String(describing: self) }
}