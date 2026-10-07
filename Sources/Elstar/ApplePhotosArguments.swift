import Foundation

public nonisolated struct ApplePhotosArguments: Decodable, Sendable {
    public var date: String?
    public var startDate: String?
    public var endDate: String?
    public var albumName: String?
    public var favoritesOnly: Bool?
    public var screenshotsOnly: Bool?
    public var limit: Int?
    public var answerQuestion: Bool?

    public init(date: String? = nil, startDate: String? = nil, endDate: String? = nil, albumName: String? = nil, favoritesOnly: Bool? = nil, screenshotsOnly: Bool? = nil, limit: Int? = nil, answerQuestion: Bool? = nil) {
        self.date = date
        self.startDate = startDate
        self.endDate = endDate
        self.albumName = albumName
        self.favoritesOnly = favoritesOnly
        self.screenshotsOnly = screenshotsOnly
        self.limit = limit
        self.answerQuestion = answerQuestion
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let allowed: Set<String> = ["date", "startDate", "endDate", "albumName", "favoritesOnly", "screenshotsOnly", "limit", "answerQuestion"]
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Only photo metadata filters are supported."))
        }
        date = try container.decodeIfPresent(String.self, forKey: Key(stringValue: "date")!)
        startDate = try container.decodeIfPresent(String.self, forKey: Key(stringValue: "startDate")!)
        endDate = try container.decodeIfPresent(String.self, forKey: Key(stringValue: "endDate")!)
        albumName = try container.decodeIfPresent(String.self, forKey: Key(stringValue: "albumName")!)
        favoritesOnly = try container.decodeIfPresent(Bool.self, forKey: Key(stringValue: "favoritesOnly")!)
        screenshotsOnly = try container.decodeIfPresent(Bool.self, forKey: Key(stringValue: "screenshotsOnly")!)
        limit = try container.decodeIfPresent(Int.self, forKey: Key(stringValue: "limit")!)
        answerQuestion = try container.decodeIfPresent(Bool.self, forKey: Key(stringValue: "answerQuestion")!)
    }

    public func query(calendar: Calendar = .current) throws -> ApplePhotosQuery {
        if date != nil, startDate != nil || endDate != nil {
            throw AppleToolError.invalidInput("Use either one photo date or a start and end date.")
        }
        let start: Date?
        let end: Date?
        if let date {
            start = try parseDay(date, calendar: calendar)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start!) else { throw AppleToolError.invalidInput("That photo date isn't supported.") }
            end = nextDay
        } else {
            start = try startDate.map { try parseDay($0, calendar: calendar) }
            end = try endDate.map { try parseDay($0, calendar: calendar) }
        }
        return try ApplePhotosQuery(start: start, end: end, albumName: albumName, favoritesOnly: favoritesOnly ?? false, screenshotsOnly: screenshotsOnly ?? false, limit: limit ?? 12)
    }

    private func parseDay(_ text: String, calendar: Calendar) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard text.utf8.count == 10, let day = formatter.date(from: text), formatter.string(from: day) == text else {
            throw AppleToolError.invalidInput("Use photo dates in YYYY-MM-DD format.")
        }
        return day
    }
}
