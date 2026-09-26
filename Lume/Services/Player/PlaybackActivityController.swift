//
//  PlaybackActivityController.swift
//  Lume
//
//  Drives the lock-screen / Dynamic Island Live Activity for the active
//  playback session (iOS only). `NowPlayingService` owns the lifecycle: one
//  activity per player session, updated in place on play/pause, seeks,
//  channel surfs and EPG programme boundaries, ended when the player closes.
//

#if os(iOS)
    import ActivityKit
    import OSLog
    import UIKit

    final class PlaybackActivityController {
        static let shared = PlaybackActivityController()

        private var activity: Activity<PlaybackActivityAttributes>?
        private var artworkFileName: String?
        /// The media id the current artwork file belongs to, so a channel surf
        /// swaps the image but a duplicate set for the same stream is skipped.
        private var artworkMediaID: String?

        private init() {}

        /// Request the activity on first call, update it in place afterwards.
        func startOrUpdate(state: PlaybackActivityAttributes.ContentState) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            var state = state
            state.artworkFileName = artworkFileName
            let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state))
            if let activity {
                Task { await activity.update(content) }
                return
            }
            // One playback activity at a time: anything still showing belongs to
            // a session that never closed its player (see `endOrphanedActivities`).
            endOrphanedActivities()
            do {
                activity = try Activity.request(
                    attributes: PlaybackActivityAttributes(sessionID: UUID().uuidString),
                    content: content
                )
            } catch {
                Logger.player.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Write a downscaled artwork copy into the app-group container. The
        /// widget extension can't load network images, so this file is the only
        /// way the activity gets artwork. Takes effect on the next state update.
        func setArtwork(_ image: UIImage, mediaID: String) {
            guard artworkMediaID != mediaID else { return }
            guard let directory = PlaybackActivityArtworkStore.directoryURL else { return }
            let scaled = Self.downscale(image, maxEdge: 256)
            guard let data = scaled.jpegData(compressionQuality: 0.8) else { return }
            let fileName = "artwork-\(abs(mediaID.hashValue)).jpg"
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                artworkFileName = fileName
                artworkMediaID = mediaID
            } catch {
                Logger.player.error("Live Activity artwork write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// When the activity's content stops being trustworthy without an update.
        ///
        /// - Live: at the programme boundary (a refresh follows).
        /// - Playing VOD: at the projected end of the title — the bar is a
        ///   self-running timer, so past that point it only describes a session
        ///   that stopped reporting.
        /// - Paused VOD: the bar is frozen, so it stays accurate; allow a long
        ///   pause.
        static func staleDate(for state: PlaybackActivityAttributes.ContentState, now: Date = .now) -> Date? {
            if state.isLive { return state.windowEnd }
            if !state.isPaused, let end = state.windowEnd, end > now { return end }
            return now.addingTimeInterval(4 * 60 * 60)
        }

        /// Ends playback activities this process doesn't own.
        ///
        /// The controller only knows the activity it requested itself. When the
        /// app goes away without the player closing — killed in the background,
        /// swiped away mid-playback, a crash — that activity outlives the process,
        /// its self-running progress bar ticking on for hours with nothing left to
        /// pause, update or end it; a relaunch never learned of it. Called at
        /// launch and before every request, so a stranded activity is cleared the
        /// next time the app runs.
        func endOrphanedActivities() {
            for orphan in Activity<PlaybackActivityAttributes>.activities where orphan.id != activity?.id {
                Task { await orphan.end(nil, dismissalPolicy: .immediate) }
            }
        }

        func end() {
            artworkFileName = nil
            artworkMediaID = nil
            guard let activity else { return }
            self.activity = nil
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
                if let directory = PlaybackActivityArtworkStore.directoryURL {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }

        private nonisolated static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
            let longest = max(image.size.width, image.size.height)
            guard longest > maxEdge, longest > 0 else { return image }
            let scale = maxEdge / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
#endif
