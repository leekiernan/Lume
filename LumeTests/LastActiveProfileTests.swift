//
//  LastActiveProfileTests.swift
//  LumeTests
//
//  Every launch starts on the profile last chosen on any of the account's
//  devices — through the ordinary switch, and never out of a child profile.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

/// Serialized and global: both stores live in `UserDefaults.standard`.
@MainActor
@Suite(.serialized, .globalState)
struct LastActiveProfileTests {
    private func makeManager(_ container: ModelContainer) -> ProfileManager {
        let coordinator = CloudSyncCoordinator(
            catalogContainer: container,
            cloudContainer: container,
            cloudKitContainerIdentifier: "iCloud.lume.tests.invalid",
            cloudKitEnabled: false
        )
        return ProfileManager(catalogContainer: container, cloudContainer: container, coordinator: coordinator)
    }

    /// Two profiles; this device on `local`, the account last on `chosen`.
    private func launch(
        localIsChild: Bool = false,
        chosenExists: Bool = true,
        body: (ProfileManager, _ local: UUID, _ chosen: UUID) async throws -> Void
    ) async throws {
        let container = try makeProfileTestContainer()
        let local = UUID()
        let chosen = UUID()
        container.mainContext.insert(UserProfile(id: local, name: "Here", isChild: localIsChild))
        if chosenExists { container.mainContext.insert(UserProfile(id: chosen, name: "Elsewhere")) }
        try container.mainContext.save()

        let savedActive = ActiveProfileStore.current
        let savedLast = LastActiveProfile.id
        defer {
            ActiveProfileStore.current = savedActive
            LastActiveProfile.id = savedLast
        }
        ActiveProfileStore.current = local
        LastActiveProfile.id = chosen

        try await body(makeManager(container), local, chosen)
    }

    @Test func `a launch starts on the account's last-used profile`() async throws {
        try await launch { manager, _, chosen in
            await manager.bootstrap()
            #expect(manager.activeProfileID == chosen)
            #expect(ActiveProfileStore.current == chosen)
        }
    }

    /// A parent's choice elsewhere must not lift a child's TV out of their
    /// profile without the PIN.
    @Test func `a device on a child profile stays on it`() async throws {
        try await launch(localIsChild: true) { manager, local, _ in
            await manager.bootstrap()
            #expect(manager.activeProfileID == local)
        }
    }

    /// Created on another device and not imported here yet.
    @Test func `a profile this device doesn't have yet is not followed`() async throws {
        try await launch(chosenExists: false) { manager, local, _ in
            await manager.bootstrap()
            #expect(manager.activeProfileID == local)
        }
    }

    @Test func `choosing a profile records it for every device`() async throws {
        try await launch { manager, local, _ in
            LastActiveProfile.id = nil
            await manager.bootstrap()
            #expect(manager.activeProfileID == local)

            manager.createProfile(name: "New", symbolName: "person.fill", color: .blue)
            let created = try #require(manager.allProfiles().first { $0.name == "New" })
            let switched = await manager.switchProfile(to: created.id)
            #expect(switched)
            #expect(LastActiveProfile.id == created.id)
        }
    }
}
