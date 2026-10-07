import Foundation
#if canImport(Photos)
import Photos

public nonisolated final class PhotoKitPhotosService: ApplePhotosService, @unchecked Sendable {
    public init() {}

    public func find(_ query: ApplePhotosQuery) async throws -> ApplePhotosPresentation {
        try Task.checkCancellation()
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        try Task.checkCancellation()
        switch status {
        case .authorized, .limited: break
        case .restricted: throw AppleToolError.permissionRestricted("Photos")
        case .denied: throw AppleToolError.permissionDenied("Photos")
        default: throw AppleToolError.notAvailable("Photos access isn't available.")
        }
        let options = PHFetchOptions()
        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue), NSPredicate(format: "hidden == NO")]
        if let start = query.start, let end = query.end {
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate))
        }
        if query.favoritesOnly { predicates.append(NSPredicate(format: "favorite == YES")) }
        if query.screenshotsOnly { predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = query.limit + 1
        options.includeHiddenAssets = false
        let assets: PHFetchResult<PHAsset>
        if let album = query.albumName {
            let albumOptions = PHFetchOptions()
            albumOptions.predicate = NSPredicate(format: "localizedTitle ==[cd] %@", album)
            let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumOptions)
            guard matches.count == 1 else {
                if matches.count == 0 { throw AppleToolError.notFound("No accessible album named \(album) was found.") }
                throw AppleToolError.invalidInput("More than one album has that name. Choose a uniquely named album.")
            }
            assets = PHAsset.fetchAssets(in: matches.object(at: 0), options: options)
        } else {
            assets = PHAsset.fetchAssets(with: .image, options: options)
        }
        var records: [ApplePhotoRecord] = []
        for index in 0..<min(assets.count, query.limit) {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            records.append(ApplePhotoRecord(id: asset.localIdentifier, creationDate: asset.creationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, isFavorite: asset.isFavorite, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }
        return ApplePhotosPresentation(photos: records, limitedAccess: status == .limited, hasMore: assets.count > query.limit)
    }
}
#else
public typealias PhotoKitPhotosService = UnavailableApplePhotosService
#endif
