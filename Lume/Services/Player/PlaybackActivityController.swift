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
        private var lastUpdate: Date?
        private var updateTask: Task<Void, Never>?

        private init() {}

        /// Request the activity on first call, update it in place afterwards.
        func startOrUpdate(state: PlaybackActivityAttributes.ContentState) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            var state = state
            state.artworkFileName = artworkFileName
            let now = Date.now
            state.freshUntil = Self.staleDate(for: state, now: now)
            let content = ActivityContent(state: state, staleDate: state.freshUntil)
            if let activity {
                lastUpdate = now
                let previous = updateTask
                updateTask = Task { [weak self] in
                    await previous?.value
                    guard self?.activity?.id == activity.id else { return }
                    await activity.update(content)
                }
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
                lastUpdate = now
            } catch {
                Logger.player.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Renew independently of clock drift: healthy steady playback used to
        /// produce no activity updates until a seek, pause or artwork change.
        func refreshIfNeeded(state: PlaybackActivityAttributes.ContentState) {
            guard PlaybackActivityFreshness.needsRenewal(lastUpdate: lastUpdate, now: .now) else { return }
            startOrUpdate(state: state)
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
        /// Every state needs a heartbeat, including a long pause. Live programme
        /// boundaries and a playing title's end can invalidate it sooner.
        static func staleDate(for state: PlaybackActivityAttributes.ContentState, now: Date = .now) -> Date {
            let advancing = state.status.map { $0 == .playing } ?? !state.isPaused
            let end = state.isLive || advancing ? state.windowEnd : nil
            return PlaybackActivityFreshness.deadline(now: now, windowEnd: end)
        }

        /// Ends playback activities this process doesn't own.
        ///
        /// The controller only knows the activity it requested itself. When the
        /// app goes away without the player closing — killed in the background,
        /// swiped away mid-playback, a crash — that activity outlives the process.
        /// Freshness prevents it claiming ongoing playback, but only another app
        /// run can remove it. Called at launch and before every request so the
        /// new process clears activities it has no in-memory ownership of.
        func endOrphanedActivities() {
            for orphan in Activity<PlaybackActivityAttributes>.activities where orphan.id != activity?.id {
                Task { await orphan.end(nil, dismissalPolicy: .immediate) }
            }
        }

        func end() {
            lastUpdate = nil
            artworkFileName = nil
            artworkMediaID = nil
            guard let activity else { return }
            self.activity = nil
            let pendingUpdate = updateTask
            updateTask = nil
            Task {
                await pendingUpdate?.value
                await activity.end(nil, dismissalPolicy: .immediate)
                if self.activity == nil, let directory = PlaybackActivityArtworkStore.directoryURL {
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
