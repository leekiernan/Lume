//
//  SectionFeed+HeroArtwork.swift
//  Lume
//
//  Bounded enrichment for the promoted section's carousel artwork.
//

import Foundation
import SwiftData

extension SectionFeed {
    enum HeroArtworkKind {
        case movie
        case series
    }

    struct HeroArtworkRequest {
        let id: String
        let heroID: String
        let tmdbId: Int
        let kind: HeroArtworkKind
        let needsBackdrop: Bool
    }

    struct HeroPresentation {
        let backdropPath: String?
        let logoPath: String?
        let overview: String?

        init(_ details: TMDBTitleDetails) {
            backdropPath = details.backdropPath
            logoPath = details.logoPath
            overview = details.overview
        }
    }

    /// Missing hero artwork is enriched in the background. The 14-day guard
    /// avoids repeatedly asking TMDB for artwork it does not have.
    private static func heroNeedsArtwork(backdropPath: String?, logoPath: String?, enrichedAt: Date?) -> Bool {
        guard (backdropPath ?? "").isEmpty || (logoPath ?? "").isEmpty else { return false }
        guard let enrichedAt else { return true }
        return Date().timeIntervalSince(enrichedAt) >= 14 * 24 * 3600
    }

    /// Fetches artwork only for the carousel's bounded visible candidates.
    func refreshHeroArtwork() async {
        guard let context, heroRef != nil else { return }
        let revision = loadGate.revision
        let candidates = Array(heroCandidates.prefix(Self.heroLimit))
        guard !candidates.isEmpty else { return }

        // On a clean catalog most candidates have only portrait provider art.
        // Build value-only requests before leaving the main actor; managed
        // models must never cross into the task-group children.
        var requests = candidates.compactMap(heroArtworkRequest)
        requests.removeAll { request in
            !heroEnrichmentIDs.insert(request.id).inserted
        }
        guard !requests.isEmpty else { return }
        let enrichmentIDs = requests.map(\.id)
        defer { heroEnrichmentIDs.subtract(enrichmentIDs) }

        // Make an entirely empty hero useful after one request, then finish the
        // remaining bounded set concurrently. Previously all eight ran serially
        // and the sole revision bump came at the end: Movies stayed blank while
        // Home/Series appeared truncated during a cold launch.
        if let firstMissingBackdrop = requests.firstIndex(where: \.needsBackdrop) {
            requests.swapAt(0, firstMissingBackdrop)
        }
        let manager = ContentSyncManager(modelContainer: context.modelContext.container)
        let firstRequest = requests.removeFirst()
        let firstDetails = await enrichHeroArtwork(firstRequest, using: manager)
        publishHeroArtworkChange(heroID: firstRequest.heroID, details: firstDetails, contextRevision: revision)
        guard !Task.isCancelled, revision == loadGate.revision else { return }

        await enrichRemainingHeroArtwork(requests, using: manager, contextRevision: revision)
    }

    private func enrichRemainingHeroArtwork(
        _ requests: [HeroArtworkRequest],
        using manager: ContentSyncManager,
        contextRevision: UInt
    ) async {
        let concurrency = 2
        for start in stride(from: 0, to: requests.count, by: concurrency) {
            guard !Task.isCancelled, contextRevision == loadGate.revision else { return }
            let end = min(start + concurrency, requests.count)
            let batch = requests[start ..< end]
            await withTaskGroup(of: (String, TMDBTitleDetails?).self) { group in
                for request in batch {
                    let id = request.id
                    let heroID = request.heroID
                    let tmdbId = request.tmdbId
                    switch request.kind {
                    case .movie:
                        group.addTask {
                            guard !Task.isCancelled else { return (heroID, nil) }
                            let details = await manager.enrichMovie(id: id, tmdbId: tmdbId)
                            return (heroID, details)
                        }
                    case .series:
                        group.addTask {
                            guard !Task.isCancelled else { return (heroID, nil) }
                            let details = await manager.enrichSeries(id: id, tmdbId: tmdbId)
                            return (heroID, details)
                        }
                    }
                }
                for await (heroID, details) in group {
                    publishHeroArtworkChange(
                        heroID: heroID,
                        details: details,
                        contextRevision: contextRevision
                    )
                }
            }
        }
    }

    private func heroArtworkRequest(_ hero: HeroItem) -> HeroArtworkRequest? {
        // An override means this session already fetched the model's currently
        // stale fields; do not let a later feed loader issue the same request.
        guard heroPresentationOverrides[hero.id] == nil else { return nil }
        switch hero {
        case let .movie(movie, _, _, _):
            guard Self.heroNeedsArtwork(
                backdropPath: movie.backdropPath,
                logoPath: movie.logoPath,
                enrichedAt: movie.tmdbEnrichedAt
            ), let tmdbId = movie.tmdbId else { return nil }
            return HeroArtworkRequest(
                id: movie.id,
                heroID: hero.id,
                tmdbId: tmdbId,
                kind: .movie,
                needsBackdrop: (movie.backdropPath ?? "").isEmpty
            )
        case let .series(series, _, _, _):
            guard Self.heroNeedsArtwork(
                backdropPath: series.backdropPath,
                logoPath: series.logoPath,
                enrichedAt: series.tmdbEnrichedAt
            ), let tmdbId = series.tmdbId else { return nil }
            return HeroArtworkRequest(
                id: series.id,
                heroID: hero.id,
                tmdbId: tmdbId,
                kind: .series,
                needsBackdrop: (series.backdropPath ?? "").isEmpty
            )
        }
    }

    private func enrichHeroArtwork(
        _ request: HeroArtworkRequest,
        using manager: ContentSyncManager
    ) async -> TMDBTitleDetails? {
        switch request.kind {
        case .movie:
            await manager.enrichMovie(id: request.id, tmdbId: request.tmdbId)
        case .series:
            await manager.enrichSeries(id: request.id, tmdbId: request.tmdbId)
        }
    }

    /// Render the fetched backdrop from a value snapshot immediately. The view
    /// context may continue serving its stale pre-enrichment model until the
    /// screen or app is recreated, despite the background save succeeding.
    private func publishHeroArtworkChange(
        heroID: String,
        details: TMDBTitleDetails?,
        contextRevision: UInt
    ) {
        guard contextRevision == loadGate.revision else { return }
        if let details { heroPresentationOverrides[heroID] = HeroPresentation(details) }
        heroArtworkRevision &+= 1
    }
}
