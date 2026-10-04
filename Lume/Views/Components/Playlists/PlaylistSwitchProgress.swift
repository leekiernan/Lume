import SwiftUI

/// Tracks an in-flight global playlist switch so the UI can show a brief blocking
/// overlay while the content tabs re-render for the newly-selected playlist.
///
/// Switching playlist flips a single `@AppStorage` value that Home, Movies,
/// Series and Live TV all observe, forcing a large synchronous re-render (the
/// catalog is filtered in-memory per playlist) plus a wave of poster loads — long
/// enough to read as a frozen UI. We surface that work: flip `isSwitching` first,
/// apply the selection one run-loop later so the overlay paints before the hitch,
/// then fade out once the new content has had a moment to settle.
@MainActor
@Observable
final class PlaylistSwitchModel {
    private var presentation = PlaylistSwitchPresentationMachine()

    var isSwitching: Bool {
        presentation.isSwitching
    }

    var targetName: String {
        presentation.targetName
    }

    /// Minimum time the overlay stays up after the selection is applied. There is
    /// no "content ready" signal to wait on (the per-playlist scope is a
    /// synchronous SwiftData filter), so this covers the re-render and the first
    /// wave of poster loads without flashing away instantly.
    private let settleDuration: Duration = .milliseconds(450)

    /// Reads the exact request's one-shot deferral. Deliberately does not mark
    /// the playlist attempted: skipping the cover for this switch must not skip
    /// it for the rest of the session.
    func consumeDeferredDueSync(for playlistID: String) -> Bool {
        presentation.consumeDueSyncDeferral(for: playlistID)
    }

    /// Begins a switch to `name`, deferring the caller's `apply` (the actual
    /// `@AppStorage` write) until the overlay is on screen.
    func switchTo(
        id: String,
        name: String,
        deferringDueSync: Bool = false,
        apply: @escaping () -> Void
    ) {
        guard let request = presentation.begin(
            targetID: id,
            targetName: name,
            defersDueSync: deferringDueSync
        ) else { return }
        Task { @MainActor [weak self] in
            // Defer the selection write so the overlay is committed before the
            // heavy re-render it triggers (see type doc).
            await Task.yield()
            guard let self, presentation.apply(request) else { return }
            apply()
            try? await Task.sleep(for: settleDuration)
            presentation.finish(request)
        }
    }
}

extension View {
    /// Layers the blocking switch-progress overlay over this view for whichever
    /// switch is in flight. The fade lives here rather than on the call site so
    /// the animated transaction covers the overlay layer only — attached to the
    /// tab hierarchy it would open one over every animatable attribute in every
    /// live tab.
    func switchProgressOverlay(playlist: PlaylistSwitchModel?, profile: ProfileManager?) -> some View {
        overlay {
            ZStack {
                if let message = switchProgressMessage(playlist: playlist, profile: profile) {
                    SwitchProgressOverlay(message: message)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: playlist?.isSwitching)
            .animation(.easeInOut(duration: 0.2), value: profile?.isSwitching)
        }
    }
}

/// The message for the switch in flight, or `nil` when none is. The profile case
/// stays up for the whole asynchronous re-projection, the playlist case for a
/// fixed settle.
private func switchProgressMessage(playlist: PlaylistSwitchModel?, profile: ProfileManager?) -> Text? {
    if let playlist, playlist.isSwitching {
        return Text(
            "Switching to \(playlist.targetName)",
            comment: "Loading message shown while the app switches to another IPTV playlist"
        )
    }
    if let profile, profile.isSwitching {
        return Text(
            "Switching profile to \(profile.pendingProfileName ?? "")",
            comment: "Loading message shown while the app switches to another user profile"
        )
    }
    return nil
}

/// The visual every switch shares.
private struct SwitchProgressOverlay: View {
    let message: Text

    var body: some View {
        ZStack {
            // Dim and capture taps so the half-rendered catalog isn't
            // interacted with mid-switch.
            Color.black.opacity(0.35)

            VStack(spacing: spacing) {
                ProgressView()
                    .controlSize(controlSize)
                    // Explicit white (not accentColor, which resolves to white on
                    // tvOS but reads as untinted elsewhere) over the dim backdrop.
                    .tint(.white)

                message
                    .font(font)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(padding)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    #if os(tvOS)
        private let spacing: CGFloat = 32
        private let padding: CGFloat = 56
        private let controlSize: ControlSize = .extraLarge
        private let font: Font = .title2
    #else
        private let spacing: CGFloat = 20
        private let padding: CGFloat = 32
        private let controlSize: ControlSize = .large
        private let font: Font = .headline
    #endif
}

#Preview("Playlist") {
    SwitchProgressOverlay(message: Text(verbatim: "Switching to My IPTV"))
}

#Preview("Profile") {
    SwitchProgressOverlay(message: Text(verbatim: "Switching profile to Profile 2"))
}
