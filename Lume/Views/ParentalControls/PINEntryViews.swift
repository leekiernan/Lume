//
//  PINEntryViews.swift
//  Lume
//
//  The PIN flows built on `PINPadView`:
//    • `PINUnlockView`   — verify the existing PIN (gate switching / Content Mgmt).
//    • `PINCreateView`   — choose a new PIN, entered twice to confirm.
//    • `ChangePINFlow`   — verify the current PIN, then choose a new one.
//    • `PINFlowView`     — set / change / turn off a PIN, over caller storage.
//  Each clears the pad and shows an inline error on a wrong/mismatched entry.
//

import SwiftUI

/// Verifies the stored PIN. Calls `onUnlock` once the entered PIN matches.
struct PINUnlockView: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let onUnlock: () -> Void
    var onCancel: (() -> Void)?
    /// Overrides global parental-PIN verification for profile-specific gates.
    var verifier: ((String) -> Bool)?

    @Environment(ParentalControls.self) private var parental: ParentalControls?
    @State private var entry = ""
    @State private var failed = false

    var body: some View {
        PINFlowScaffold(onCancel: onCancel) {
            PINPadView(
                title: title,
                subtitle: failed ? "Incorrect PIN. Try again." : subtitle,
                entry: $entry
            )
        }
        .onChange(of: entry) { _, value in
            guard value.count == ParentalControls.pinLength else { return }
            let isValid = verifier?(value) ?? (parental?.verify(value) == true)
            if isValid {
                entry = ""
                onUnlock()
            } else {
                failed = true
                entry = ""
            }
        }
    }
}

/// Collects a new PIN twice and reports it once both entries match.
struct PINCreateView: View {
    let onComplete: (String) -> Void
    var onCancel: (() -> Void)?

    @State private var firstEntry = ""
    @State private var entry = ""
    @State private var mismatch = false

    private var confirming: Bool {
        !firstEntry.isEmpty
    }

    var body: some View {
        PINFlowScaffold(onCancel: onCancel) {
            PINPadView(
                title: confirming ? "Confirm PIN" : "Set a PIN",
                subtitle: subtitle,
                entry: $entry
            )
        }
        .onChange(of: entry) { _, value in
            guard value.count == ParentalControls.pinLength else { return }
            if !confirming {
                firstEntry = value
                entry = ""
                mismatch = false
            } else if value == firstEntry {
                onComplete(value)
            } else {
                mismatch = true
                firstEntry = ""
                entry = ""
            }
        }
    }

    private var subtitle: LocalizedStringKey {
        if mismatch { return "PINs didn't match. Try again." }
        return confirming ? "Re-enter your PIN to confirm." : "Choose a 4-digit PIN."
    }
}

/// Verifies the current PIN, then collects a replacement.
struct ChangePINFlow: View {
    let onComplete: (String) -> Void
    var onCancel: (() -> Void)?
    var verifier: ((String) -> Bool)?

    @State private var verified = false

    var body: some View {
        if verified {
            PINCreateView(onComplete: onComplete, onCancel: onCancel)
        } else {
            PINUnlockView(
                title: "Enter Current PIN",
                subtitle: "Enter your current PIN to change it.",
                onUnlock: { verified = true },
                onCancel: onCancel,
                verifier: verifier
            )
        }
    }
}

/// Which PIN operation a flow performs. Identifiable so it can drive a sheet.
enum PINFlow: String, Identifiable {
    case set, change, remove

    var id: String {
        rawValue
    }
}

/// Runs a single PIN operation to completion, then calls `onFinish` (which the
/// presenter uses to dismiss). Storage is the caller's: the parental-control
/// PIN (profile management) and a profile's own synced hash (the profile
/// editor) run the same flows against different `verify` / `save` / `clear`.
/// Changing or removing a PIN requires entering the current one first.
struct PINFlowView: View {
    let flow: PINFlow
    /// Checks an entered PIN against the current one.
    let verify: (String) -> Bool
    /// Stores a newly chosen PIN.
    let save: (String) -> Void
    /// Turns the PIN off.
    let clear: () -> Void
    let onFinish: () -> Void

    var body: some View {
        switch flow {
        case .set:
            PINCreateView(onComplete: complete, onCancel: onFinish)
        case .change:
            ChangePINFlow(
                onComplete: complete,
                onCancel: onFinish,
                verifier: verify
            )
        case .remove:
            PINUnlockView(
                title: "Turn Off PIN",
                subtitle: "Enter your current PIN to turn it off.",
                onUnlock: {
                    clear()
                    onFinish()
                },
                onCancel: onFinish,
                verifier: verify
            )
        }
    }

    private func complete(_ pin: String) {
        save(pin)
        onFinish()
    }
}

/// Shared chrome for a PIN flow: centres the pad and, when cancellable, offers a
/// Cancel button below it. Keeps the pad itself free of presentation concerns so
/// it works inline (Content Management gate) and inside a sheet/cover alike.
private struct PINFlowScaffold<Content: View>: View {
    var onCancel: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 24) {
            content()
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(tvOS)
            .tvSettingsBackground()
        #endif
    }
}
