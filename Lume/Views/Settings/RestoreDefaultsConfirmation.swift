import SwiftUI

extension View {
    /// Native confirmation only: the caller owns presentation and the exact
    /// reset operation. Cancel and interactive dismissal never invoke it.
    func restoreDefaultsConfirmation(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        }
    }
}
