//
//  SportsHubChannels+View.swift
//  Lume
//
//  Keeps a hub's merged channel answer in state. Built as a computed property
//  it merged both machines' dictionaries on every read — per card, sometimes
//  twice — so a render cost O(fixtures²). It now rebuilds once when either
//  machine or the visibility changes.
//

import SwiftUI

private struct SportsHubChannelInputs: Equatable {
    let resolution: SportsFixtureResolutionMachine
    let highlights: SportsHighlightsLoadMachine
    let visibilityToken: String
}

extension View {
    func keepingSportsHubChannels(
        _ channels: Binding<SportsHubChannels>,
        resolution: SportsFixtureResolutionMachine,
        highlights: SportsHighlightsLoadMachine,
        visibilityToken: String
    ) -> some View {
        onChange(
            of: SportsHubChannelInputs(resolution: resolution, highlights: highlights, visibilityToken: visibilityToken),
            initial: true
        ) { _, inputs in
            channels.wrappedValue = SportsHubChannels(
                resolution: inputs.resolution, highlights: inputs.highlights, visibilityToken: inputs.visibilityToken
            )
        }
    }
}
