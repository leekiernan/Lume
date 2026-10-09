import Foundation
import SwiftData

/// Resolve the selected programme only. Hub rails deliberately omit synopses
/// from their broad scans; no managed objects cross back to the presentation.
nonisolated struct EPGProgrammeDetails {
    let synopsis: String
    let artworkURL: String?
    let subtitle: String?

    static func load(container: ModelContainer, channelID: String, cell: EPGProgramCell) throws -> Self? {
        guard !channelID.isEmpty, !cell.isGap else { return nil }
        let context = ModelContext(container)
        let id = cell.listingID ?? cell.id
        let title = cell.title
        let start = cell.start
        let end = cell.end
        // Grid cells retain their programme's ID even when their bounds are
        // clipped. Hub fallback cells instead have a synthetic ID.
        var exact = FetchDescriptor<EPGListing>(predicate: #Predicate {
            $0.id == id && $0.channelId == channelID && $0.title == title && $0.start <= start && $0.end >= end
        })
        exact.fetchLimit = 1
        if let listing = try context.fetch(exact).first { return Self(listing) }
        var fallback = FetchDescriptor<EPGListing>(predicate: #Predicate {
            $0.channelId == channelID && $0.title == title && $0.start == start && $0.end == end
        })
        fallback.fetchLimit = 2
        let matches = try context.fetch(fallback)
        guard matches.count == 1, let listing = matches.first else { return nil }
        return Self(listing)
    }

    private init(_ listing: EPGListing) {
        synopsis = listing.listingDescription
        artworkURL = listing.artworkURL
        subtitle = listing.subtitle
    }
}
