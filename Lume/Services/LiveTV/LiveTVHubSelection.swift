import Foundation
import SwiftData

/// Resolve a selected hub value through the current playlist/profile policy.
/// Menus and playback use the same boundary, including after a profile switch.
enum LiveTVHubSelection {
    static func stream(_ id: String, prefix: String, restriction: ContentRestriction, in context: ModelContext) -> LiveStream? {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id && !$0.isHidden })
        descriptor.fetchLimit = 1
        guard let stream = try? context.fetch(descriptor).first,
              stream.id.hasPrefix(prefix), !restriction.hides(categoryID: stream.categoryId) else { return nil }
        return stream
    }
}
