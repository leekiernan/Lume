//
//  LiveStreamCardView.swift
//  Lume
//
//  Card view for displaying a live stream channel
//

import SwiftUI

struct LiveStreamCardView: View {
    let stream: LiveStream
    /// The channel's now/next programmes, resolved once by the parent list (see
    /// `ChannelEPGSnapshot`) rather than by a per-card `@Query`.
    var epg: ChannelEPG?
    /// Shown above the name where channels from different categories share a
    /// list: Recently Watched, Favorites and search.
    var categoryName: String?
    /// A programme still to come, shown in place of now/next — a search result
    /// for something on later.
    var upcoming: EPGSlot?

    var body: some View {
        LiveChannelRowContent(stream: stream, epg: epg, categoryName: categoryName, upcoming: upcoming)
            .padding(.vertical, 8)
    }
}

#Preview("Basic") {
    LiveStreamCardView(
        stream: LiveStream(
            id: "preview-1",
            streamId: 1,
            name: "BBC One"
        )
    )
    .padding()
}

#Preview("With Archive") {
    LiveStreamCardView(
        stream: LiveStream(
            id: "preview-2",
            streamId: 2,
            name: "CNN International",
            tvArchive: 1,
            tvArchiveDuration: 7
        )
    )
    .padding()
}

#Preview("With Logo") {
    LiveStreamCardView(
        stream: LiveStream(
            id: "preview-3",
            streamId: 3,
            name: "National Geographic",
            streamIcon: "https://example.com/logo.png",
            epgChannelId: "NATGEO",
            tvArchive: 1,
            tvArchiveDuration: 3
        )
    )
    .padding()
}

#Preview("Favorite") {
    let stream = LiveStream(
        id: "preview-4",
        streamId: 4,
        name: "HBO",
        tvArchive: 1,
        tvArchiveDuration: 14
    )
    stream.isFavorite = true
    return LiveStreamCardView(stream: stream)
        .padding()
}
