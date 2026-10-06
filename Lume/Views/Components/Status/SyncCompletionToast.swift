import SwiftUI

private struct SyncCompletionToastModifier: ViewModifier {
    let priority: Int
    @State private var notifications = SyncCompletionNotifications.shared
    @State private var hostID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ActiveProfileStore.key) private var profileToken = ""

    private var notice: SyncCompletionNotifications.Notice? {
        notifications.notice(for: hostID, profileToken: profileToken, isActive: scenePhase == .active)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let notice {
                        SyncCompletionToast(notice: notice)
                            .id(notice.id)
                            .padding()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: notice?.id)
            }
            .onAppear { notifications.registerHost(hostID, priority: priority) }
            .onDisappear { notifications.unregisterHost(hostID) }
            .onChange(of: profileToken, initial: true) { _, token in notifications.retainProfile(token) }
            .task(id: notice?.id) {
                guard let notice else { return }
                do {
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    notifications.dismiss(notice.id)
                } catch {
                    // Hidden/backgrounded: leave the message queued for return.
                }
            }
    }
}

private struct SyncCompletionToast: View {
    let notice: SyncCompletionNotifications.Notice

    private var title: LocalizedStringKey {
        notice.outcome == .succeeded ? "Sync complete" : "Sync failed"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.outcome == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(notice.outcome == .succeeded ? Color.lumeAccent : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                switch notice.subject {
                case let .playlist(_, name): Text(verbatim: name)
                case .guide: Text("TV Guide")
                }
            }
            .lineLimit(2)
        }
        .padding()
        .frame(maxWidth: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A scene-root host uses priority zero; sheets/covers register above it.
    func syncCompletionToasts(priority: Int = 1) -> some View {
        modifier(SyncCompletionToastModifier(priority: priority))
    }
}
