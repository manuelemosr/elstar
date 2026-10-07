import Foundation
import Testing
@testable import Elstar

private struct FixedPhotosService: ApplePhotosService {
    var result: ApplePhotosPresentation
    var error: AppleToolError? = nil
    func find(_ query: ApplePhotosQuery) async throws -> ApplePhotosPresentation {
        if let error { throw error }
        return result
    }
}

@Suite("Photos executor")
struct ApplePhotosExecutorTests {
    private func executor(service: any ApplePhotosService, sink: RecordingEventSink) -> AppleToolExecutor {
        var services = AppleToolServices.unavailable()
        services.photos = service
        return AppleToolExecutor(key: HarnessConversationKey(absoluteKey: "conn/photos"), messageID: "m", tracker: RecordingTracker(), sink: sink, serializer: AppleOperationSerializer(), confirmations: AppleConfirmationStore(), journal: AppleToolJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), services: services)
    }
    @Test func limitedPhotosReachUIWithoutSendingAssetIDsToModel() async throws {
        let record = ApplePhotoRecord(id: "private-asset-reference", pixelWidth: 800, pixelHeight: 600, isFavorite: true)
        let presentation = ApplePhotosPresentation(photos: [record], limitedAccess: true, hasMore: true)
        let sink = RecordingEventSink()
        let result = try #require(await executor(service: FixedPhotosService(result: presentation), sink: sink).perform(.findPhotos(try ApplePhotosQuery())))
        #expect(result.status == .confirmed)
        #expect(result.photosPresentation == presentation)
        #expect(sink.deltas.last?.photosPresentation == presentation)
        #expect(!result.modelText.contains(record.id))
        #expect(result.modelText.contains("limited"))
        #expect(sink.interactions.isEmpty && sink.receipts.isEmpty)
    }
    @Test func deniedPermissionIsNotReportedAsAnEmptySearch() async throws {
        let sink = RecordingEventSink()
        let result = await executor(service: FixedPhotosService(result: ApplePhotosPresentation(photos: []), error: .permissionDenied("Photos")), sink: sink).perform(.findPhotos(try ApplePhotosQuery()))
        #expect(result?.status != .confirmed)
        #expect(result?.photosPresentation == nil)
        #expect(sink.deltas.last?.status == .failed)
    }
}
