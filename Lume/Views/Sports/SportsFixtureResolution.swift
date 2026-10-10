//
//  SportsFixtureResolution.swift
//  Lume
//
//  Drives a view's `SportsFixtureResolutionMachine` from its `.task(id:)`.
//

import SwiftData
import SwiftUI

/// Runs a `SportsFixtureResolutionMachine` request against the resolver.
@MainActor
enum SportsFixtureResolution {
    /// - Parameter soonestFirst: publish the games starting soon before the
    ///   whole set (the hubs and league screen), or one pass (the Home rails,
    ///   whose handful of fixtures gains nothing from it).
    static func run(
        _ machine: Binding<SportsFixtureResolutionMachine>,
        fixtures: [SportsFixture],
        container: ModelContainer,
        restriction: ContentRestriction,
        soonestFirst: Bool = true
    ) async {
        guard let request = machine.wrappedValue.begin(fixtures, visibilityToken: restriction.visibilityToken) else { return }
        EPGSyncService.shared.ensureCoverage(reason: "Sports fixtures")
        if soonestFirst {
            await SportsChannelResolver.resolveSoonestFirst(
                container: container,
                fixtures: fixtures,
                restriction: restriction,
                publish: { machine.wrappedValue.publish(request, $0) }
            )
        } else {
            let answer = await SportsChannelResolver.resolve(container: container, fixtures: fixtures, restriction: restriction)
            guard !Task.isCancelled else { return }
            machine.wrappedValue.publish(request, answer)
        }
    }
}
