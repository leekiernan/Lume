import Foundation
import SwiftData

/// CloudKit-synced mirror of the account-wide app settings — the player and
/// search choices a viewer expects to follow them between devices (engine
/// priority, languages, playback toggles, …). `AccountSettingsSync` lists the
/// keys and does the merging; `UserDefaults` stays the local store of record,
/// so every `@AppStorage` reading these keys is unchanged.
///
/// Account-wide, not profile-scoped: these describe how the app plays, not one
/// person's taste — the profile snapshot (`ProfileScopedPreferences`) carries
/// that. Engine tuning (buffers, hardware decode) and the external player stay
/// per device: an Apple TV and a phone want different ones.
///
/// A singleton in practice — `id` is always `Self.singletonID`. CloudKit cannot
/// enforce uniqueness, so two devices can each insert one before they converge;
/// the reconciler dedupes on `updatedAt`.
///
/// CloudKit constraints honoured: every stored property is defaulted, there is
/// no `@Attribute(.unique)`, and there are no relationships.
@Model
final class SyncedAccountSettings {
    /// The only id this record ever uses, so every device addresses the same
    /// row without having to agree on one first.
    static let singletonID = "account-settings"

    var id: String = SyncedAccountSettings.singletonID
    /// The settings as JSON (`AccountSettingsSync.encode`). Keys this build
    /// doesn't know — added by a newer version — are kept, never dropped.
    var valuesJSON: String = ""
    /// Last time the values changed. Used only to dedupe duplicate singletons;
    /// correctness rests on the shadow baseline, not this clock.
    var updatedAt: Date = Date()

    init(valuesJSON: String, updatedAt: Date = Date()) {
        self.valuesJSON = valuesJSON
        self.updatedAt = updatedAt
    }
}
