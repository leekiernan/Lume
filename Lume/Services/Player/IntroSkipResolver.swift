import Foundation
import OSLog
import SwiftData
import Synchronization

/// Resolves the IntroDB lookup key — the *series'* IMDb id plus the season and
/// episode numbers — for the content currently playing.
///
/// IntroDB only indexes episodic TV (its segments endpoint requires a season
/// and episode), so movies and live streams resolve to `nil` and simply get no
/// skip affordance. Cross-platform: the host (`FullScreenPlayerView`) owns the
/// lookup and the async fetch, handing the result down to whichever engine is
/// active — mirroring `NextEpisodeResolver`.
enum IntroSkipResolver {
    struct Lookup: Hashable {
        let imdbId: String
        let season: Int
        let episode: Int
    }

    /// The IntroDB lookup key for `ref`, or `nil` when it is not an episode, the
    /// episode / series can't be resolved, or the series carries no IMDb id.
    static func lookup(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Lookup? {
        guard case let .episode(id) = ref else { return nil }

        guard let episode = PlayerContentLookup.episode(id, in: context),
              let imdbId = episode.series?.imdbId?.trimmingCharacters(in: .whitespaces),
              !imdbId.isEmpty else { return nil }

        return Lookup(imdbId: imdbId, season: episode.seasonNum, episode: episode.episodeNum)
    }

    /// Answers already fetched this run, including "IntroDB has nothing". A
    /// resume, a rewatch or a surf back to the episode then has its windows
    /// before the first frame. Failures aren't kept, so the next open retries.
    private static let answers = Mutex<[Lookup: IntroSegments?]>([:])

    /// The segments for `lookup`, from this run's answers or from IntroDB,
    /// journalled with how long they took and where the playhead was — the
    /// line that tells a late answer from a window that doesn't fit this cut.
    static func segments(for lookup: Lookup, playhead: @MainActor () -> TimeInterval) async -> IntroSegments? {
        let key = "\(lookup.imdbId) S\(lookup.season)E\(lookup.episode)"
        if let cached = answers.withLock({ $0[lookup] }) {
            Logger.player.info("intro segments: \(key, privacy: .public) cached — \(describe(cached), privacy: .public)")
            return cached
        }
        let started = ContinuousClock.now
        do {
            let segments = try await IntroDBClient.shared.segments(
                imdbId: lookup.imdbId, season: lookup.season, episode: lookup.episode
            )
            answers.withLock { $0[lookup] = segments }
            let elapsed = Int((ContinuousClock.now - started) / .milliseconds(1))
            let position = Int(playhead())
            Logger.player.info(
                "intro segments: \(key, privacy: .public) in \(elapsed) ms at \(position) s — \(describe(segments), privacy: .public)"
            )
            return segments
        } catch {
            Logger.player.error("intro segments: \(key, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func describe(_ segments: IntroSegments?) -> String {
        guard let segments else { return "none" }
        let parts = [
            segments.recap.map { "recap \($0.logName)" },
            segments.intro.map { "intro \($0.logName)" },
            segments.outro.map { "outro \($0.logName)" }
        ].compactMap(\.self)
        return parts.joined(separator: ", ")
    }
}
