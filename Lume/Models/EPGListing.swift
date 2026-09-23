import Foundation
import SwiftData

@Model
final class EPGListing {
    // EPG is the largest, fastest-growing table for big playlists (a multi-week
    // XMLTV guide for thousands of channels runs to hundreds of thousands of
    // rows). Every now/next lookup and the guide window query filter by
    // `channelId` and the `start`/`end` time bounds, so index them — without
    // these, each channel card and guide open scans the whole guide table.
    // The in-player lookups (now/next, the channel's upcoming list, the guide
    // window) all bound on `end > now` rather than on `start`, so the
    // `channelId + start` pair above can only seek to the channel and then walk
    // every listing it ever had. `channelId + end` is the pair those predicates
    // actually ask for — `TVPlayerContent.guideListings` has claimed this index
    // in a comment since it was written, without it ever existing.
    #Index<EPGListing>(
        [\.channelId],
        [\.start],
        [\.end],
        [\.channelId, \.start],
        [\.channelId, \.end],
        [\.sourceID]
    )

    @Attribute(.unique) var id: String

    /// The XMLTV channel ID this listing belongs to.
    /// LiveStreams reference the same value via their `epgChannelId`.
    var channelId: String
    var title: String
    var listingDescription: String
    var start: Date
    var end: Date
    /// The source that committed this row. Refreshing one source only replaces
    /// its own snapshot, never every guide row ahead of a successful fetch.
    var sourceID: UUID?

    /// XMLTV `<sub-title>` — episode title for series, or the fixture line for a
    /// sports broadcast. Optional/defaulted so adding it is a lightweight
    /// migration; deliberately kept out of the guide loaders' `propertiesToFetch`
    /// so the hot now/next and guide-window fetches don't pay for it.
    var subtitle: String?
    /// XMLTV `<category>` values joined with ", " — the signal the Sports Hub
    /// uses to spot sports broadcasts.
    var category: String?

    init(
        id: String,
        channelId: String,
        title: String,
        listingDescription: String,
        start: Date,
        end: Date,
        sourceID: UUID? = nil,
        subtitle: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.channelId = channelId
        self.title = title
        self.listingDescription = listingDescription
        self.start = start
        self.end = end
        self.sourceID = sourceID
        self.subtitle = subtitle
        self.category = category
    }

    /// Updates every field a refresh can change, skipping the write when a
    /// field is already current — `EPGSyncManager.replaceSnapshot` retains
    /// rows across a refresh instead of deleting and reinserting them (see its
    /// own comment), so an unmoved field should cost nothing.
    func update(from programme: ParsedProgramme, category: String?) {
        if channelId != programme.channelId { channelId = programme.channelId }
        if title != programme.title { title = programme.title }
        if listingDescription != programme.description { listingDescription = programme.description }
        if start != programme.start { start = programme.start }
        if end != programme.end { end = programme.end }
        if subtitle != programme.subtitle { subtitle = programme.subtitle }
        if self.category != category { self.category = category }
    }
}
