import Foundation

// MARK: - Credential minimisation

public nonisolated enum DeveloperChatDiagnosticsScrub {
    private static let patterns: [(String, String)] = [
        (#"(?i)\b(authorization|proxy-authorization)\s*:\s*[^\s,;]+"#, "$1: [redacted]"),
        (#"(?i)\b(bearer)\s+[A-Za-z0-9._\-+/=]{8,}"#, "$1 [redacted]"),
        (#"(?i)\b(api[-_]?key|apikey|password|passwd|secret|token)\b\s*[:=]\s*"?[^\s"',;]+"?"#, "$1=[redacted]"),
        (#"(?i)\bsk-[A-Za-z0-9_\-]{8,}"#, "[redacted-key]"),
        (#"(?i)(https?://)[^/\s@]+@"#, "$1[redacted]@"),
    ]

    /// Minimise known credential values and common credential patterns. This is
    /// NOT a general secret redactor and does not pretend to be one: chat
    /// content is preserved by design.
    public static func scrub(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        return result
    }
}

// MARK: - Structured tool arguments

/// Explicit, typed mapping from every `AppleToolRequest` to a stable structured
/// argument map, so a recorded tool call carries real fields instead of an
/// unparseable `String(describing:)` or an opaque request signature.
public nonisolated enum DeveloperChatToolArguments {
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    public static func describe(_ request: AppleToolRequest) -> [String: String] {
        var fields: [String: String] = [
            "operation": request.operation.rawValue,
            "family": request.family.rawValue,
            "isMutation": request.isMutation ? "true" : "false",
        ]
        switch request {
        case .currentTime, .listReminderLists:
            break
        case .findPhotos(let query):
            if let start = query.start { fields["start"] = iso.string(from: start) }
            if let end = query.end { fields["end"] = iso.string(from: end) }
            if let album = query.albumName { fields["albumName"] = album }
            fields["favoritesOnly"] = String(query.favoritesOnly)
            fields["screenshotsOnly"] = String(query.screenshotsOnly)
            fields["limit"] = String(query.limit)
        case .calculate(let expression):
            fields["expression"] = expression
        case .listReminders(let listID):
            if let listID { fields["listID"] = listID }
        case .listCalendarEvents(let q), .calendarAvailability(let q):
            fields["start"] = iso.string(from: q.start)
            fields["end"] = iso.string(from: q.end)
            if let calendarID = q.calendarID { fields["calendarID"] = calendarID }
        case .searchNearbyPlaces(let r):
            fields["query"] = r.query
            fields["anchor"] = r.anchor.key
            fields["limit"] = String(r.limit)
        case .currentPlace(let r):
            fields["reverseGeocode"] = r.reverseGeocode ? "true" : "false"
        case .directions(let r):
            fields["destinationID"] = r.destinationID
            fields["destinationName"] = r.destinationName
            if let address = r.destinationAddress { fields["destinationAddress"] = address }
            fields["mode"] = r.mode.rawValue
        case .weather(let r):
            fields["anchor"] = r.anchor.key
            switch r.kind {
            case .current: fields["kind"] = "current"
            case .forecast(let days): fields["kind"] = "forecast"; fields["days"] = String(days)
            case .hourly(let hours): fields["kind"] = "hourly"; fields["hours"] = String(hours)
            }
        case .fetchWebPage(let r):
            fields["url"] = DeveloperChatDiagnosticsScrub.scrub(r.url.absoluteString)
        }
        return fields
    }

    public static func receipt(_ receipt: AppleToolReceipt?) -> [String: String]? {
        guard let receipt else { return nil }
        var fields: [String: String] = [
            "operationID": receipt.operationID,
            "family": receipt.family.rawValue,
            "action": receipt.action,
            "status": receipt.status.rawValue,
            "summary": receipt.summary,
        ]
        if let nativeID = receipt.nativeID { fields["nativeID"] = nativeID }
        if let detail = receipt.detail { fields["detail"] = detail }
        return fields
    }

    /// Full, bounded structured result fields for a tool result event: the
    /// status, the summary, every returned display item (title/subtitle/real
    /// reference), and the receipt. Not summary-only, so a recorded result can
    /// be inspected without re-reading the transcript. Kept as a small number
    /// of fields so the store's field/value bounds never drop the receipt.
    public static func result(_ result: AppleToolResult) -> [String: String] {
        var fields: [String: String] = [
            "status": result.status.rawValue,
            "summary": result.summary,
            "itemCount": String(result.items.count),
        ]
        let items: [[String: String]] = result.items.prefix(16).map { item in
            var entry: [String: String] = ["title": item.title]
            if let subtitle = item.subtitle { entry["subtitle"] = subtitle }
            if let reference = item.reference { entry["reference"] = reference }
            return entry
        }
        if !items.isEmpty, let data = try? JSONEncoder().encode(items), let json = String(data: data, encoding: .utf8) {
            fields["items"] = json
        }
        if let resultReceipt = result.receipt {
            for (key, value) in receipt(resultReceipt) ?? [:] {
                fields["receipt.\(key)"] = value
            }
        }
        return fields
    }
}
