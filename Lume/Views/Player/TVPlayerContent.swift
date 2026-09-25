//
//  TVPlayerContent.swift
//  Lume
//
//  SwiftData lookups that back the tvOS in-player overlay. Given the value-type
//  `PlayableMedia` the player knows about, these resolve the underlying model
//  objects (episode + sibling episodes, movie, live stream + EPG) so the
//  overlay can render the episode rail, the information panel and the EPG
//  caption, and build a `PlayableMedia` for a newly-picked episode. Guide
//  reads run off the main actor and return plain values.
//

#if os(tvOS)

    import Foundation
    import SwiftData

    enum TVPlayerContent {
        // MARK: - Model lookups

        static func episode(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Episode? {
            guard case let .episode(id) = ref else { return nil }
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }

        static func movie(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Movie? {
            guard case let .movie(id) = ref else { return nil }
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }

        static func liveStream(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> LiveStream? {
            guard case let .live(id) = ref else { return nil }
            var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }

        // MARK: - Episodes

        /// Episodes of the given episode's season, ordered by episode number —
        /// the content of the in-player episode rail.
        static func seasonEpisodes(for episode: Episode) -> [Episode] {
            guard let series = episode.series else { return [episode] }
            return series.episodes
                .filter { $0.seasonNum == episode.seasonNum }
                .sorted { $0.episodeNum < $1.episodeNum }
        }

        /// The playlist that owns a series, mirroring the detail screen's logic
        /// (prefix match on the playlist UUID, falling back to the first one).
        static func playlist(for series: Series?, in context: ModelContext) -> Playlist? {
            let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
            guard let series else { return playlists.first }
            return playlists.first { series.id.hasPrefix($0.id.uuidString) } ?? playlists.first
        }

        // MARK: - EPG (off the main actor)

        // Every guide read below runs on a fresh `ModelContext` from a detached
        // task, returning plain `EPGWindowListing` values — the same pattern as
        // `ChannelEPGLoader` / `PlayerStreamInfo`. These fire while a stream is
        // starting and on every focus move in the channel browser; on the view
        // context they hydrated managed rows (description included) on the
        // main thread while the player was decoding.

        /// The titles of the programmes airing right now on the given channels,
        /// keyed by EPG channel id — a single fetch that backs the subtitle line
        /// on each card in the "Recent" rail and the browser's channel column.
        static func nowProgrammeTitles(for channels: [LiveStream], container: ModelContainer) async -> [String: String] {
            let epgIds = Set(channels.compactMap(\.epgChannelId).filter { !$0.isEmpty })
            guard !epgIds.isEmpty else { return [:] }
            let now = Date()
            return await Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<EPGListing>(
                    predicate: #Predicate { epgIds.contains($0.channelId) && $0.start <= now && now < $0.end }
                )
                descriptor.propertiesToFetch = [\.channelId, \.title]
                let listings = (try? context.fetch(descriptor)) ?? []
                return Dictionary(listings.map { ($0.channelId, $0.title) }, uniquingKeysWith: { first, _ in first })
            }.value
        }

        /// How many rows the now/next fetch reads. Its caller
        /// (`TVPlayerControlsOverlay.resolveContent`) needs exactly two — the
        /// programme airing now and the one after it — and, ordered by start,
        /// those are the first two rows. Unbounded, the fetch handed it the
        /// channel's whole remaining guide instead: 615 rows on the measured
        /// store, 1,209 on the busiest channel, hydrated on every controls wake
        /// and every channel surf while the stream decodes. The slack above two
        /// absorbs the overlapping and duplicated entries providers ship, which
        /// would otherwise push "next" out of the window.
        private nonisolated static let nowNextLimit = 6

        /// The programme airing now on a channel and the one after it. The
        /// `channelId + end` index seeks straight to the remaining guide.
        static func nowNext(
            channelId: String?,
            container: ModelContainer
        ) async -> (now: EPGWindowListing?, next: EPGWindowListing?) {
            guard let channelId, !channelId.isEmpty else { return (nil, nil) }
            let now = Date()
            return await Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<EPGListing>(
                    predicate: #Predicate { $0.channelId == channelId && $0.end > now },
                    sortBy: [SortDescriptor(\.start)]
                )
                descriptor.fetchLimit = nowNextLimit
                let listings = ((try? context.fetch(descriptor)) ?? []).map(EPGWindowListing.init)
                return (
                    listings.first { $0.start <= now && now < $0.end },
                    listings.first { $0.start > now }
                )
            }.value
        }

        /// How far ahead the in-player guide lists. The browser's guide column
        /// is a quick "what's on" and a way into catch-up, not the full guide —
        /// which runs to weeks of future listings on some providers.
        private nonisolated static let guideLookahead: TimeInterval = 24 * 3600

        /// Hard cap on the guide column's rows, for channels whose archive
        /// reaches back far enough to hold thousands of short programmes. The
        /// newest rows are kept: the recent past and what's coming up.
        private nonisolated static let guideRowLimit = 400

        /// EPG listings for the in-player guide, oldest first. With
        /// `archiveDays > 0` (a catch-up channel) it reaches back over the
        /// archive window so already-aired programmes are available to replay;
        /// otherwise it starts at what's airing now. Either way it stops a day
        /// ahead (`guideLookahead`), is capped at `guideRowLimit` rows, and
        /// fetches only the columns a row shows — never the description.
        static func guideListings(
            channelId: String?,
            archiveDays: Int,
            container: ModelContainer
        ) async -> [EPGWindowListing] {
            guard let channelId, !channelId.isEmpty else { return [] }
            let now = Date()
            let earliest = archiveDays > 0 ? CatchupWindow.earliestStart(archiveDays: archiveDays, now: now) : now
            let latest = now.addingTimeInterval(guideLookahead)
            return await Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                // Newest first so the cap trims the oldest archive rows, then
                // flipped back into airing order.
                var descriptor = FetchDescriptor<EPGListing>(
                    predicate: #Predicate { $0.channelId == channelId && $0.end > earliest && $0.start < latest },
                    sortBy: [SortDescriptor(\.start, order: .reverse)]
                )
                descriptor.fetchLimit = guideRowLimit
                descriptor.propertiesToFetch = [\.id, \.title, \.start, \.end]
                let listings = (try? context.fetch(descriptor)) ?? []
                return listings.reversed().map {
                    EPGWindowListing(id: $0.id, title: $0.title, detail: "", start: $0.start, end: $0.end)
                }
            }.value
        }
    }

#endif
