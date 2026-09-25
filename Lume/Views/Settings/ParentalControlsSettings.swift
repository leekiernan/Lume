//
//  ParentalControlsSettings.swift
//  Lume
//
//  The PIN-management flow: set, change or turn off the parental-control PIN.
//  Changing or removing the PIN requires entering the current one, so a child
//  can't disable the gate (only Content Management is fully locked; the rest of
//  Settings stays reachable). Lives in profile management — `ManageProfilesView`
//  (iOS/macOS) and the tvOS Profiles pane both drive `ParentalPINFlowView`.
//

import SwiftUI

/// `PINFlowView` over the parental-control PIN (the keychain item behind
/// `ParentalControls`), which it reads from the environment.
struct ParentalPINFlowView: View {
    let flow: PINFlow
    let onFinish: () -> Void

    @Environment(ParentalControls.self) private var parental: ParentalControls?

    var body: some View {
        PINFlowView(
            flow: flow,
            verify: { parental?.verify($0) == true },
            save: { parental?.setPIN($0) },
            clear: { parental?.disablePIN() },
            onFinish: onFinish
        )
    }
}
