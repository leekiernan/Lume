import SwiftUI

#if os(macOS)
    import AppKit

    extension EnvironmentValues {
        @Entry var macSettingsNavigation = false
    }

    /// Destination-owned dismissal also works for view-based NavigationLinks:
    /// those pushes aren't represented in a bound NavigationPath.
    private struct MacNavigationBack: ViewModifier {
        var rootAction: (() -> Void)?
        @Environment(\.dismiss) private var dismiss
        @Environment(\.isPresented) private var isPresented
        @Environment(\.macSettingsNavigation) private var settings
        @State private var active = false

        private var canGoBack: Bool {
            rootAction != nil || isPresented
        }

        private func back() {
            if let rootAction { rootAction() } else { dismiss() }
        }

        private func keyboardBack() {
            // Let editors cancel editing without unexpectedly leaving the page.
            guard let window = NSApp.keyWindow,
                  MacWindowShortcutPolicy.accepts(isEditingText: window.firstResponder is NSTextView,
                                                  hasPresentedSheet: window.attachedSheet != nil) else { return }
            back()
        }

        func body(content: Content) -> some View {
            content
                .navigationBarBackButtonHidden(settings && rootAction == nil && isPresented)
                .toolbar {
                    if settings, rootAction == nil, isPresented {
                        ToolbarItem(placement: .navigation) {
                            Button(action: back) { Label("Back", systemImage: "chevron.left") }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                        }
                    }
                }
                .background {
                    Button("Back", action: keyboardBack)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!active || !canGoBack)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
                .onAppear { active = true }
                .onDisappear { active = false }
        }
    }
#endif

extension View {
    func macNavigationBack(rootAction: (() -> Void)? = nil) -> some View {
        #if os(macOS)
            modifier(MacNavigationBack(rootAction: rootAction))
        #else
            self
        #endif
    }
}
