import CoreData
import Foundation
import OSLog
import SwiftData
import SwiftUI

/// UI-facing facade for user profiles. Owns the active-profile selection and the
/// profile roster's lifecycle; delegates the heavy, off-main store work (catalog
/// re-projection on switch, legacy migration, content purge) to
/// `CloudSyncCoordinator`/`CloudSyncEngine`, which already run on a background
/// `ModelContext`.
///
/// Simple `UserProfile` CRUD happens directly on the main context — those are
/// cheap single-row writes and SwiftData merges the engine's background saves
/// back into it, so `@Query`-driven UI stays consistent.
@MainActor
@Observable
final class ProfileManager {
    private(set) var activeProfileID: UUID {
        didSet { activeProfile = profile(with: activeProfileID) }
    }

    /// Cached active profile, refreshed whenever `activeProfileID` changes. Avoids
    /// a SwiftData fetch on every SwiftUI body that reads it (the switcher chip
    /// lives in toolbars and the settings screen, which re-render often).
    private(set) var activeProfile: UserProfile?

    /// Whether the active profile is a child — drives content restriction across
    /// the browse, Home and Search surfaces.
    var activeProfileIsChild: Bool {
        activeProfile?.isChild ?? false
    }

    /// True once launch bootstrap has resolved the active profile and claimed any
    /// legacy records. The switcher waits on this before offering a switch.
    private(set) var isReady = false
    /// The profile a switch is re-projecting the catalog onto. The single stored
    /// piece of switch state — the flag and the overlay's copy both derive from
    /// it, so they cannot drift apart.
    private var switchingToProfileID: UUID?

    /// True while a profile switch is re-projecting the catalog — the UI blocks
    /// interaction so a half-projected catalog is never shown.
    var isSwitching: Bool {
        switchingToProfileID != nil
    }

    /// Name of the profile being switched to, for the blocking progress overlay.
    var pendingProfileName: String? {
        switchingToProfileID.flatMap {
            QuickSwitchResolver.currentProfile(in: profiles, activeProfileID: $0)?.name
        }
    }

    /// The profile roster the UI reads (instead of a `@Query`). `UserProfile`
    /// lives in the cloud store — a separate container the browse `@Query`s don't
    /// bind to — so the profile views can't query it directly; they observe this
    /// instead. Refreshed after each mutation and on CloudKit remote-change. Field
    /// edits to existing profiles propagate via the `@Model`'s own observation, so
    /// this array only changes when the *set* of profiles does.
    private(set) var profiles: [UserProfile] = []

    /// Holds `UserProfile` (the CloudKit-mirrored store); all profile CRUD runs on
    /// its main context.
    private let cloudContainer: ModelContainer
    /// The local-only catalog store. Used only to flush pending catalog edits
    /// before a profile switch, so the engine's background pass reads current state.
    private let catalogContainer: ModelContainer
    private let coordinator: CloudSyncCoordinator
    /// Process-lifetime; never removed (this manager lives for the whole app).
    private var remoteChangeObserver: NSObjectProtocol?
    private var cloudImportObserver: NSObjectProtocol?
    private var preferencesChangeObserver: NSObjectProtocol?
    private var preferencesSaveTask: Task<Void, Never>?
    private var lastPreferencesSnapshot: ProfilePreferencesSnapshot?
    private var lastPreferencesJSON: String?
    private var isApplyingPreferences = false
    private static let preferencesSaveDelay: Duration = .milliseconds(250)

    init(catalogContainer: ModelContainer, cloudContainer: ModelContainer, coordinator: CloudSyncCoordinator) {
        self.catalogContainer = catalogContainer
        self.cloudContainer = cloudContainer
        self.coordinator = coordinator
        activeProfileID = ActiveProfileStore.current ?? UserProfile.defaultProfileID
        // `didSet` doesn't fire for the in-init assignment above, so seed the
        // cache directly (same single-row fetch shape) — keeps a profile resolved
        // on a prior launch available before `bootstrap()` runs.
        let resolvedID = activeProfileID
        var descriptor = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == resolvedID })
        descriptor.fetchLimit = 1
        activeProfile = (try? cloudContainer.mainContext.fetch(descriptor))?.first
        profiles = allProfiles()
        // `UserProfile` syncs via CloudKit; refresh the roster when a remote change
        // (a profile added/removed on another device) lands. Only the cloud store
        // posts this — the catalog store is local-only. Cheap (a few rows) and
        // guarded, so the constant import churn doesn't re-render the profile UI.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshProfiles()
                self?.applyImportedPreferencesIfNeeded()
            }
        }
        // A generic store-change can be an export acknowledgement or an early
        // import batch. Only a completed successful import proves that an empty
        // `preferencesJSON` is genuinely empty in CloudKit and safe to seed.
        cloudImportObserver = NotificationCenter.default.addObserver(
            forName: .lumeCloudImportDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudImportDidComplete() }
        }
        // `@AppStorage` writes straight to UserDefaults, so mirror relevant
        // changes back onto the active cloud profile. The notification is broad;
        // snapshot comparison below filters out every device-only preference.
        preferencesChangeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesDidChange() }
        }
    }

    /// `UserProfile` lives in the cloud store, so all profile CRUD runs on the
    /// cloud container's main context.
    private var context: ModelContext {
        cloudContainer.mainContext
    }

    // MARK: - Launch

    /// Ensure a default profile exists, resolve the active profile and claim any
    /// pre-profiles content records. Run once at launch, before the first sync.
    func bootstrap() async {
        let result = await coordinator.bootstrapProfiles(
            preferredActiveID: ActiveProfileStore.current,
            defaultName: String(localized: "Profile 1", comment: "Name of the automatically-created first profile")
        )
        ActiveProfileStore.current = result.activeProfileID
        activeProfileID = result.activeProfileID
        // The active profile is settled, so the layout someone had before
        // layout became per-profile can now be adopted as theirs. Runs before
        // `isReady`, and so before any view reads a layout key.
        ProfileScopedPreferences.migrateLegacyValuesIfNeeded()
        synchronizePreferences(
            for: result.activeProfileID,
            allowCloudSeed: coordinator.canSeedProfilePreferences
        )
        isReady = true
        refreshProfiles()
    }

    // MARK: - Queries

    func allProfiles() -> [UserProfile] {
        let descriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Re-read the roster from the cloud store, reassigning `profiles` only when
    /// the *set* changed — so CloudKit's constant remote-change churn doesn't
    /// needlessly re-render the profile UI (field edits propagate via `@Model`).
    private func refreshProfiles() {
        let latest = allProfiles()
        if latest.map(\.persistentModelID) != profiles.map(\.persistentModelID) {
            profiles = latest
        }
    }

    func profile(with id: UUID) -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Mutations

    @discardableResult
    func createProfile(name: String, symbolName: String, color: ProfileColor, isChild: Bool = false) -> UserProfile {
        let profile = UserProfile(
            name: name,
            symbolName: symbolName,
            colorRaw: color.rawValue,
            sortOrder: (try? context.fetchCount(FetchDescriptor<UserProfile>())) ?? 0,
            isChild: isChild
        )
        context.insert(profile)
        try? context.save()
        refreshProfiles()
        return profile
    }

    func updateProfile(_ profile: UserProfile, name: String, symbolName: String, color: ProfileColor, isChild: Bool) {
        profile.name = name
        profile.symbolName = symbolName
        profile.colorRaw = color.rawValue
        profile.isChild = isChild
        profile.updatedAt = Date()
        try? context.save()
    }

    func updateProfilePIN(_ profile: UserProfile, pinHash: String) {
        guard profile.pinHash != pinHash else { return }
        profile.pinHash = pinHash
        profile.updatedAt = Date()
        try? context.save()
    }

    /// Re-project the catalog onto another profile's saved state.
    func switchProfile(to id: UUID) async {
        guard id != activeProfileID, !isSwitching else { return }
        let from = activeProfileID
        switchingToProfileID = id
        preferencesSaveTask?.cancel()
        preferencesSaveTask = nil
        persistPreferencesIfChanged(for: from)
        // Flush any pending catalog edits (e.g. a favorite toggled moments ago,
        // not yet autosaved) so the engine — which reads the catalog through its
        // own background context — exports the outgoing profile's *current* state
        // rather than a stale snapshot. This flushes the CATALOG main context;
        // profile rows live in the separate cloud store.
        try? catalogContainer.mainContext.save()
        // The engine commits `ActiveProfileStore.current = id` atomically with
        // the projection swap (see `CloudSyncEngine.switchProfile`), so there is
        // no window where the catalog and the active-profile pointer disagree.
        await coordinator.switchProfile(from: from, to: id)
        activeProfileID = id
        lastPreferencesSnapshot = nil
        lastPreferencesJSON = nil
        synchronizePreferences(for: id, allowCloudSeed: coordinator.canSeedProfilePreferences)
        switchingToProfileID = nil
        // Re-baseline the freshly projected state against the cloud.
        coordinator.reconcile()
    }

    /// Delete a profile and all of its saved watch state. The last remaining
    /// profile can't be deleted. Deleting the active profile first switches to a
    /// surviving one so the catalog never keeps projecting the deleted profile.
    func deleteProfile(_ profile: UserProfile) async {
        let remaining = allProfiles().filter { $0.id != profile.id }
        guard let fallback = remaining.first else {
            Logger.sync.error("Refusing to delete the last remaining profile")
            return
        }
        if profile.id == activeProfileID {
            await switchProfile(to: fallback.id)
        }
        await coordinator.purgeProfileData(profile.id)
        LiveChannelHistory.purge(profileID: profile.id)
        context.delete(profile)
        try? context.save()
        refreshProfiles()
    }

    // MARK: - Synced preferences

    /// First use on a device is asymmetric on purpose: a non-empty CloudKit
    /// snapshot always wins. Existing local values can seed an empty snapshot
    /// only after a successful import has established that the empty field is
    /// current, rather than a stale pre-import copy of another device's profile.
    private func synchronizePreferences(
        for profileID: UUID,
        allowCloudSeed: Bool,
        preservingPendingLocalChanges: Bool = false
    ) {
        guard let profile = profile(with: profileID) else { return }
        let local = ProfileScopedPreferences.snapshot(profileID: profileID)
        let pendingBaseline = pendingPreferencesBaseline(
            for: local,
            preservingPendingLocalChanges: preservingPendingLocalChanges
        )
        guard !profile.preferencesJSON.isEmpty else {
            synchronizeEmptyPreferences(
                local,
                profile: profile,
                profileID: profileID,
                allowCloudSeed: allowCloudSeed,
                pendingBaseline: pendingBaseline
            )
            return
        }
        guard let imported = ProfileScopedPreferences.decode(profile.preferencesJSON) else {
            Logger.sync.error("Ignoring malformed synced preferences for profile \(profileID.uuidString, privacy: .public)")
            // Keep a pending local change dirty so its debounce can replace the
            // malformed payload with a valid snapshot instead of silently
            // accepting that it was saved.
            guard pendingBaseline == nil else { return }
            lastPreferencesSnapshot = local
            lastPreferencesJSON = profile.preferencesJSON
            return
        }
        applyImportedPreferences(imported, local: local, pendingBaseline: pendingBaseline, to: profile)
    }

    private func pendingPreferencesBaseline(
        for local: ProfilePreferencesSnapshot,
        preservingPendingLocalChanges: Bool
    ) -> ProfilePreferencesSnapshot? {
        guard preservingPendingLocalChanges,
              let lastPreferencesSnapshot,
              local != lastPreferencesSnapshot
        else { return nil }
        return lastPreferencesSnapshot
    }

    private func synchronizeEmptyPreferences(
        _ local: ProfilePreferencesSnapshot,
        profile: UserProfile,
        profileID: UUID,
        allowCloudSeed: Bool,
        pendingBaseline: ProfilePreferencesSnapshot?
    ) {
        // A completed import proves the empty payload is current. Preserve an
        // edit made while that import was running by publishing it now. Before
        // completion, leave its debounce task alone rather than treating a
        // possibly-stale empty row as authoritative.
        if pendingBaseline != nil {
            guard allowCloudSeed else { return }
            cancelPendingPreferencesSave()
            persistPreferences(local, to: profile)
            return
        }
        lastPreferencesSnapshot = local
        lastPreferencesJSON = ""
        if ProfileScopedPreferences.shouldSeedCloudSnapshot(
            cloudJSON: profile.preferencesJSON,
            hasCompletedCloudImport: allowCloudSeed,
            hasStoredLocalValues: ProfileScopedPreferences.hasStoredValues(profileID: profileID)
        ) {
            persistPreferences(local, to: profile)
        }
    }

    private func applyImportedPreferences(
        _ imported: ProfilePreferencesSnapshot,
        local: ProfilePreferencesSnapshot,
        pendingBaseline: ProfilePreferencesSnapshot?,
        to profile: UserProfile
    ) {
        let resolved = if let pendingBaseline {
            ProfileScopedPreferences.merging(
                remote: imported,
                withLocalChanges: local,
                since: pendingBaseline
            )
        } else {
            imported
        }
        if pendingBaseline != nil {
            cancelPendingPreferencesSave()
        }
        isApplyingPreferences = true
        ProfileScopedPreferences.apply(resolved, profileID: profile.id)
        isApplyingPreferences = false
        let applied = ProfileScopedPreferences.snapshot(profileID: profile.id)
        if pendingBaseline != nil {
            // Publish the merged document so the local edit travels to the other
            // devices as well. `persistPreferences` retains remote fields from a
            // newer app version that this build does not understand.
            persistPreferences(applied, to: profile)
        } else {
            lastPreferencesSnapshot = applied
            lastPreferencesJSON = profile.preferencesJSON
        }
    }

    private func cancelPendingPreferencesSave() {
        preferencesSaveTask?.cancel()
        preferencesSaveTask = nil
    }

    /// A remote-store notification can also concern playlists, Trakt or an
    /// inactive profile. Apply only when the active profile's payload changed.
    private func applyImportedPreferencesIfNeeded() {
        guard isReady, !isSwitching,
              let profile = profile(with: activeProfileID),
              profile.preferencesJSON != lastPreferencesJSON
        else { return }
        synchronizePreferences(
            for: activeProfileID,
            allowCloudSeed: coordinator.canSeedProfilePreferences,
            preservingPendingLocalChanges: true
        )
    }

    private func cloudImportDidComplete() {
        guard isReady, !isSwitching else { return }
        synchronizePreferences(
            for: activeProfileID,
            allowCloudSeed: true,
            preservingPendingLocalChanges: true
        )
    }

    private func preferencesDidChange() {
        guard isReady, !isSwitching, !isApplyingPreferences else { return }
        let current = ProfileScopedPreferences.snapshot(profileID: activeProfileID)
        guard current != lastPreferencesSnapshot else { return }
        preferencesSaveTask?.cancel()
        let profileID = activeProfileID
        preferencesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.preferencesSaveDelay)
            guard !Task.isCancelled, self?.activeProfileID == profileID else { return }
            self?.persistPreferencesIfChanged(for: profileID)
        }
    }

    private func persistPreferencesIfChanged(for profileID: UUID) {
        let current = ProfileScopedPreferences.snapshot(profileID: profileID)
        guard current != lastPreferencesSnapshot,
              let profile = profile(with: profileID)
        else { return }
        persistPreferences(current, to: profile)
    }

    private func persistPreferences(_ current: ProfilePreferencesSnapshot, to profile: UserProfile) {
        let previous = ProfileScopedPreferences.decode(profile.preferencesJSON)
        let merged = ProfileScopedPreferences.preservingUnknownValues(in: previous, updating: current)
        guard let encoded = ProfileScopedPreferences.encode(merged) else { return }
        guard encoded != profile.preferencesJSON else {
            lastPreferencesSnapshot = current
            lastPreferencesJSON = encoded
            return
        }
        profile.preferencesJSON = encoded
        profile.updatedAt = Date()
        do {
            try context.save()
            lastPreferencesSnapshot = current
            lastPreferencesJSON = encoded
        } catch {
            Logger.sync.error("Saving synced profile preferences failed: \(error.localizedDescription)")
        }
    }
}
