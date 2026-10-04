import SwiftUI

/// The view-lifetime timer driver for PlayerChromeMachine. Only actual
/// visibility changes publish: renewing a deadline must not redraw menus.
@MainActor
@Observable
final class PlayerChromeController {
    private(set) var isVisible = true
    @ObservationIgnored private var machine = PlayerChromeMachine()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func activate() {
        active = true
    }

    func deactivate() {
        active = false
        suspend()
    }

    func show() {
        suspend()
        machine.show()
        publishVisibility()
    }

    func hide() {
        suspend()
        machine.hide()
        publishVisibility()
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Scrubbing, open panels/browser and disappearance release deadlines.
    func suspend() {
        timer?.cancel()
        timer = nil
        machine.cancelDeadline()
    }

    func schedule(_ deadline: PlayerChromeMachine.Deadline = .inactivity, mayHide: @escaping () -> Bool) {
        suspend()
        guard active, let request = machine.schedule(deadline, mayHide: mayHide()) else { return }
        let sleep = sleep
        timer = Task { @MainActor [weak self] in
            do { try await sleep(request.deadline.delay) } catch { return }
            guard !Task.isCancelled, let self, active else { return }
            // Check the current host, including VoiceOver, not a captured Bool.
            if machine.fire(request, mayHide: mayHide()) { publishVisibility() }
        }
    }

    private func publishVisibility() {
        guard isVisible != machine.isVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isVisible = machine.isVisible }
    }
}

extension View {
    /// Native pointer handling only; keyboard and playback commands stay in
    /// their host. The same timer owns both the 4s and 600ms hide deadlines.
    func playerPointerChrome(_ chrome: PlayerChromeController, mayHide: @escaping () -> Bool) -> some View {
        modifier(PlayerPointerChrome(chrome: chrome, mayHide: mayHide))
    }
}

private struct PlayerPointerChrome: ViewModifier {
    let chrome: PlayerChromeController
    let mayHide: () -> Bool

    func body(content: Content) -> some View {
        #if os(macOS)
            content.onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active:
                    chrome.show()
                    chrome.schedule(mayHide: mayHide)
                case .ended:
                    chrome.schedule(.pointerExit, mayHide: mayHide)
                }
            }
        #else
            content
        #endif
    }
}
