//
//  PlaybackLiveActivity.swift
//  LumeWidgets
//
//  Lock-screen banner + Dynamic Island for the active playback session.
//  Everything renders from the content state pushed by the app's
//  `NowPlayingService`; tapping any surface deep-links back into playback.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct PlaybackLiveActivity: Widget {
    private static let resumeURL = URL(string: "lume://resume")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            PlaybackLockScreenView(state: context.state, status: context.state.presentation(isStale: context.isStale))
                .widgetURL(Self.resumeURL)
        } dynamicIsland: { context in
            let status = context.state.presentation(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlaybackArtworkView(fileName: context.state.artworkFileName, size: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isLive, status == .playing {
                        LiveBadge()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: status.symbolName)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let secondary = context.state.programmeTitle ?? context.state.subtitle {
                            Text(secondary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        PlaybackProgressView(state: context.state, status: status)
                        PlaybackStatusLabel(status: status)
                        if status != .unavailable { PlaybackUpNextView(state: context.state) }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PlaybackArtworkView(fileName: context.state.artworkFileName, size: 23)
            } compactTrailing: {
                if !status.advancesProgress {
                    Image(systemName: status.symbolName)
                        .foregroundStyle(.secondary)
                } else if context.state.isLive {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.red)
                } else if let start = context.state.windowStart, let end = context.state.windowEnd, start < end {
                    ProgressView(timerInterval: start ... end, countsDown: false) {} currentValueLabel: {}
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            } minimal: {
                Image(systemName: status.symbolName)
                    .foregroundStyle(context.state.isLive && status == .playing ? .red : .white)
            }
            .widgetURL(Self.resumeURL)
        }
    }
}

/// The lock-screen / banner presentation.
private struct PlaybackLockScreenView: View {
    let state: PlaybackActivityAttributes.ContentState
    let status: PlaybackActivityStatus

    var body: some View {
        HStack(spacing: 12) {
            PlaybackArtworkView(fileName: state.artworkFileName, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if state.isLive, status == .playing {
                        LiveBadge()
                    } else if status != .playing {
                        Image(systemName: status.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let secondary = state.programmeTitle ?? state.subtitle {
                    Text(secondary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                PlaybackProgressView(state: state, status: status)
                PlaybackStatusLabel(status: status)
                if status != .unavailable { PlaybackUpNextView(state: state) }
            }
        }
        .padding(14)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(.white)
    }
}

/// Progress for the current programme (live) or the stream position (VOD).
/// Only fresh, confirmed playback advances. Loading, buffering, paused and
/// stale sessions show the last reported position, not a synthetic clock.
private struct PlaybackProgressView: View {
    let state: PlaybackActivityAttributes.ContentState
    let status: PlaybackActivityStatus

    var body: some View {
        if !status.advancesProgress, let elapsed = state.elapsed, let duration = state.duration, duration > 0 {
            ProgressView(value: min(max(elapsed / duration, 0), 1))
                .progressViewStyle(.linear)
                .tint(.white)
        } else if status.advancesProgress, let start = state.windowStart, let end = state.windowEnd, start < end {
            HStack(spacing: 8) {
                if state.isLive {
                    Text(start, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(timerInterval: start ... end, countsDown: false) {} currentValueLabel: {}
                    .progressViewStyle(.linear)
                    .tint(.white)
                if state.isLive {
                    Text(end, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

private nonisolated extension PlaybackActivityStatus {
    var symbolName: String {
        switch self {
        case .loading: "hourglass"
        case .playing: "play.fill"
        case .paused: "pause.fill"
        case .buffering: "arrow.trianglehead.2.clockwise.rotate.90"
        case .unavailable: "exclamationmark.circle"
        }
    }
}

private struct PlaybackStatusLabel: View {
    let status: PlaybackActivityStatus

    var body: some View {
        Group {
            switch status {
            case .loading: Text("Loading…", comment: "Live Activity: playback has not started")
            case .buffering: Text("Buffering…", comment: "Live Activity: playback is waiting for data")
            case .paused: Text("Paused", comment: "Live Activity: playback is paused")
            case .unavailable: Text("Playback unavailable", comment: "Live Activity: playback failed or stopped reporting")
            case .playing: EmptyView()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// The EPG "up next" line (live TV only).
private struct PlaybackUpNextView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if let nextTitle = state.nextTitle, let nextStart = state.nextStart {
            Text("\(nextStart, style: .time) · \(nextTitle)", comment: "Live Activity up-next line: start time · programme title")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct LiveBadge: View {
    var body: some View {
        Text("LIVE", comment: "Badge marking a live TV stream")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red, in: Capsule())
    }
}

/// Channel logo / poster from the app-group container, with a placeholder when
/// no artwork could be written. Widget extensions can't load network images,
/// so the file the app dropped in the shared container is the only source.
private struct PlaybackArtworkView: View {
    let fileName: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let fileName,
               let url = PlaybackActivityArtworkStore.url(for: fileName),
               let image = UIImage(contentsOfFile: url.path)
            {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
