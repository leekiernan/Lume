//
//  SportsPayPerViewConfirmation.swift
//  Lume
//
//  A pay-per-view card plays its channel straight away only while the event
//  is on. Before then the channel is usually dark — often a dead stream the
//  player retries for a minute — so the card asks first, saying when.
//

import SwiftUI

extension View {
    /// Presents the "not on yet" question for `event`, playing the channel
    /// with `onWatch` only if the viewer says so.
    func payPerViewConfirmation(
        _ event: Binding<SportsPayPerView.Event?>,
        onWatch: @escaping (SportsPayPerView.Event) -> Void
    ) -> some View {
        confirmationDialog(
            event.wrappedValue?.title ?? "",
            isPresented: event.presentationPresence(),
            titleVisibility: .visible,
            presenting: event.wrappedValue
        ) { pending in
            Button("Watch Channel Anyway") { onWatch(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.start != nil {
                Text("Not on yet — starts \(pending.whenText(now: Date())) on \(pending.channelName).")
            } else {
                Text("No start time is listed for this event on \(pending.channelName).")
            }
        }
    }
}
