import Foundation
import Testing
@testable import Elstar

@Suite("Photos metadata")
struct ApplePhotosTests {
    @Test func rejectsInvalidBounds() throws {
        #expect(throws: AppleToolError.self) { try ApplePhotosQuery(limit: 0) }
        #expect(throws: AppleToolError.self) { try ApplePhotosQuery(limit: 25) }
        #expect(throws: AppleToolError.self) { try ApplePhotosQuery(start: Date()) }
        #expect(throws: AppleToolError.self) { try ApplePhotosQuery(start: Date(timeIntervalSince1970: 2), end: Date(timeIntervalSince1970: 1)) }
        #expect(throws: AppleToolError.self) { try ApplePhotosQuery(albumName: "  ") }
    }
    @Test func trimsAlbumWithoutDiscardingFilters() throws {
        let query = try ApplePhotosQuery(albumName: " Holiday ", favoritesOnly: true, screenshotsOnly: true, limit: 24)
        #expect(query.albumName == "Holiday")
        #expect(query.favoritesOnly && query.screenshotsOnly)
        #expect(query.limit == 24)
    }
    @Test func persistsPhotoReferencesAndDecodesOldActivity() throws {
        let record = ApplePhotoRecord(id: "local-only", creationDate: Date(timeIntervalSince1970: 1), pixelWidth: 400, pixelHeight: 300)
        let activity = ToolActivity(id: "t", name: "Find photos", status: .completed, photosPresentation: ApplePhotosPresentation(photos: [record], limitedAccess: true, hasMore: true))
        let decoded = try JSONDecoder().decode(ToolActivity.self, from: JSONEncoder().encode(activity))
        #expect(decoded == activity)
        let old = try JSONDecoder().decode(ToolActivity.self, from: Data(#"{"id":"old","name":"read"}"#.utf8))
        #expect(old.photosPresentation == nil)
    }
}
