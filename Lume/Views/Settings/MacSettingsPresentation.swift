import SwiftUI

#if os(macOS)
    import AppKit

    /// Stable identity for settings opened as either a sheet or a native window.
    /// The window must remain weak: its content owns this controller.
    final class MacSettingsWindowController {
        weak var window: NSWindow?
        var dismiss: DismissAction?

        func close() {
            if window?.sheetParent != nil { dismiss?() } else { window?.performClose(nil) }
        }
    }

    extension EnvironmentValues {
        @Entry var macSettingsWindowController: MacSettingsWindowController?
    }

    private struct MacSettingsPresentation: ViewModifier {
        @Environment(\.dismiss) private var dismiss
        @State private var window = MacSettingsWindowController()

        func body(content: Content) -> some View {
            content
                .environment(\.macSettingsNavigation, true)
                .environment(\.macSettingsWindowController, window)
                .environment(\.defaultMinListRowHeight, 40)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .background(MacWindowAccessor { window.window = $0 })
                .onAppear { window.dismiss = dismiss }
                .frame(minWidth: 540, idealWidth: 650, minHeight: 500, idealHeight: 680)
        }
    }

    private struct MacSettingsRootEscape: ViewModifier {
        @Environment(\.macSettingsWindowController) private var window

        func body(content: Content) -> some View {
            content.macNavigationBack(rootAction: window.map { controller in { controller.close() } })
        }
    }

    extension View {
        func macSettingsPresentation() -> some View {
            modifier(MacSettingsPresentation())
        }

        func macSettingsRootEscape() -> some View {
            modifier(MacSettingsRootEscape())
        }
    }
#endif
