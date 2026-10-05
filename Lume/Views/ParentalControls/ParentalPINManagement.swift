import SwiftUI

/// Global parental PIN actions only. Profile-specific PIN storage stays in its
/// editor, and switch verification stays in `ProfileSwitchPINPolicy`/pinPrompt.
struct ParentalPINButtons: View {
    let isPINSet: Bool
    @Binding var flow: PINFlow?

    var body: some View {
        if isPINSet {
            action("Change PIN", symbol: "lock.rotation", flow: .change)
            action("Turn Off PIN", symbol: "lock.open", flow: .remove, destructive: true)
        } else {
            action("Set a PIN", symbol: "lock", flow: .set)
        }
    }

    private func action(
        _ title: LocalizedStringKey, symbol: String, flow target: PINFlow, destructive: Bool = false
    ) -> some View {
        Button(role: destructive ? .destructive : nil) { flow = target } label: {
            Label(title, systemImage: symbol)
            #if os(tvOS)
                .labelStyle(TVSettingsIconLabelStyle())
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVSettingsRowButtonStyle(isDestructive: destructive))
        #endif
    }
}

extension View {
    func parentalPINManagement(flow: Binding<PINFlow?>) -> some View {
        modifier(ParentalPINManagementPresentation(flow: flow))
    }
}

private struct ParentalPINManagementPresentation: ViewModifier {
    @Binding var flow: PINFlow?

    func body(content: Content) -> some View {
        #if os(tvOS)
            content.fullScreenCover(item: $flow) { target in
                ParentalPINFlowView(flow: target) { flow = nil }
            }
        #else
            content.sheet(item: $flow) { target in
                NavigationStack {
                    ParentalPINFlowView(flow: target) { flow = nil }
                        .platformNavigationTitle("Parental Controls")
                }
                #if os(macOS)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 460, idealHeight: 520)
                #endif
            }
        #endif
    }
}
