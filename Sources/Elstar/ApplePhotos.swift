import Foundation

public nonisolated struct ApplePhotosQuery: Equatable, Sendable {
    public let start: Date?
    public let end: Date?
    public let albumName: String?
    public let favoritesOnly: Bool
    public let screenshotsOnly: Bool
    public let limit: Int

    public init(start: Date? = nil, end: Date? = nil, albumName: String? = nil, favoritesOnly: Bool = false, screenshotsOnly: Bool = false, limit: Int = 12) throws {
        guard (1...24).contains(limit) else { throw AppleToolError.invalidInput("Request between 1 and 24 photos.") }
        guard (start == nil) == (end == nil) else { throw AppleToolError.invalidInput("Provide both the start and end of the photo date range.") }
        if let start, let end {
            guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start < end else {
                throw AppleToolError.invalidInput("The photo date range must end after it starts.")
            }
        }
        let album = albumName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let album { guard !album.isEmpty, album.utf8.count <= 200 else { throw AppleToolError.invalidInput("Use an album name between 1 and 200 bytes.") } }
        self.start = start
        self.end = end
        self.albumName = album
        self.favoritesOnly = favoritesOnly
        self.screenshotsOnly = screenshotsOnly
        self.limit = limit
    }
}

public nonisolated struct ApplePhotoRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var creationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isFavorite: Bool
    public var isScreenshot: Bool

    public init(id: String, creationDate: Date? = nil, pixelWidth: Int, pixelHeight: Int, isFavorite: Bool = false, isScreenshot: Bool = false) {
        self.id = id
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
    }
}

public nonisolated struct ApplePhotosPresentation: Codable, Equatable, Hashable, Sendable {
    public var photos: [ApplePhotoRecord]
    public var limitedAccess: Bool
    public var hasMore: Bool

    public init(photos: [ApplePhotoRecord], limitedAccess: Bool = false, hasMore: Bool = false) {
        self.photos = photos
        self.limitedAccess = limitedAccess
        self.hasMore = hasMore
    }
}

public nonisolated protocol ApplePhotosService: Sendable {
    func find(_ query: ApplePhotosQuery) async throws -> ApplePhotosPresentation
}

public nonisolated struct UnavailableApplePhotosService: ApplePhotosService {
    public init() {}
    public func find(_ query: ApplePhotosQuery) async throws -> ApplePhotosPresentation {
        throw AppleToolError.notAvailable("Photos isn't available on this platform.")
    }
}
