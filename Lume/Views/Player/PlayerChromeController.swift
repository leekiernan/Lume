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

    func show(mayHide: @escaping () -> Bool) {
        show()
        schedule(mayHide: mayHide)
    }

    func toggle(mayHide: @escaping () -> Bool) {
        toggle()
        if isVisible { schedule(mayHide: mayHide) }
    }

    func panelChanged(isOpen: Bool, mayHide: @escaping () -> Bool) {
        if isOpen { suspend() } else { schedule(mayHide: mayHide) }
    }

    func openBrowser(isLive: Bool, isPresented: Binding<Bool>) {
        guard isLive, !isPresented.wrappedValue else { return }
        suspend()
        withAnimation(.easeInOut(duration: 0.25)) { isPresented.wrappedValue = true }
    }

    func closeBrowser(isPresented: Binding<Bool>, mayHide: @escaping () -> Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { isPresented.wrappedValue = false }
        schedule(mayHide: mayHide)
    }

    /// Hosts retain browser focus handoff and panel tokens; ordering is shared.
    func menu(
        _ context: PlayerMenuRoute.Context,
        claimsBack: () -> Bool, closeBrowser: () -> Void, closePanel: () -> Void, closePlayer: () -> Void
    ) {
        switch PlayerMenuRoute.resolve(failed: context.failed, browserOpen: context.browserOpen, panelOpen: context.panelOpen, controlsVisible: isVisible) {
        case .closePlayer: closePlayer()
        case .closeBrowser: closeBrowser()
        case .closePanel: closePanel()
        case .hideControls: hide()
        case .handoff:
            if !claimsBack() { closePlayer() }
        }
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

/// No engine calls or focus writes: only the precedence of a Menu/back press.
nonisolated enum PlayerMenuRoute: Equatable {
    case closePlayer, closeBrowser, closePanel, hideControls, handoff

    struct Context {
        let failed: Bool
        let browserOpen: Bool
        let panelOpen: Bool
    }

    static func resolve(failed: Bool, browserOpen: Bool, panelOpen: Bool, controlsVisible: Bool) -> Self {
        if failed { return .closePlayer }
        if browserOpen { return .closeBrowser }
        if panelOpen { return .closePanel }
        return controlsVisible ? .hideControls : .handoff
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
