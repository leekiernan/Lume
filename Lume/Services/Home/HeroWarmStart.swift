//
//  HeroWarmStart.swift
//  Lume
//
//  A tiny device-local pointer to the last lead hero backdrop. The image bytes
//  themselves already live in ImageDiskCache; this only remembers which one to
//  ask for before the promoted section has resolved on a cold launch.
//

import Foundation

nonisolated struct HeroWarmStart: Codable, Equatable {
    let heroToken: String
    let catalogScope: String
    let backdropURL: String
}

enum HeroWarmStartCache {
    /// Profile-scoped because each profile can promote a different section, but
    /// deliberately absent from the iCloud preference snapshot: this is derived
    /// device-local cache metadata, not a user setting.
    static func storageKey(_ surface: SectionSurface) -> String {
        ProfileScopedPreferences.key(baseStorageKey(surface))
    }

    static func baseStorageKey(_ surface: SectionSurface) -> String {
        "\(surface.storagePrefix).heroWarmStart.v1"
    }

    /// Everything that can make a remembered hero ineligible without changing
    /// the hero token itself. The profile is already part of the storage key;
    /// this covers playlist changes, visibility/restriction changes, and an
    /// edited URL on the same custom section id.
    static func catalogScope(
        playlistID: UUID?,
        visibilityToken: String,
        hero: HomeSectionRef?,
        customSections: [CustomHomeSection]
    ) -> String {
        let source: String = if case let .custom(id) = hero,
                                let section = customSections.first(where: { $0.id == id })
        {
            section.sourceURL
        } else {
            "builtin"
        }
        return "\(playlistID?.uuidString ?? "none")|\(visibilityToken)|\(source)"
    }

    static func encode(hero: HomeSectionRef, catalogScope: String, backdropURL: URL) -> String? {
        let record = HeroWarmStart(
            heroToken: hero.token,
            catalogScope: catalogScope,
            backdropURL: backdropURL.absoluteString
        )
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the remembered URL only when it belongs to the hero and catalog
    /// currently on screen. Switching profile is handled by the scoped key;
    /// `catalogScope` covers the playlist, restrictions and custom source URL.
    static func backdropURL(
        from raw: String,
        hero: HomeSectionRef?,
        catalogScope: String
    ) -> URL? {
        guard let hero,
              let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(HeroWarmStart.self, from: data),
              record.heroToken == hero.token,
              record.catalogScope == catalogScope
        else { return nil }
        return URL(string: record.backdropURL)
    }
}

/// View-owned access to one surface's warm-start record. Keeping the UserDefaults
/// plumbing here means Home, Movies and Series share the same validation and
/// update behaviour without turning derived cache metadata into an iCloud setting.
@MainActor @Observable
final class HeroWarmStartState {
    private let key: String
    private let defaults: UserDefaults
    private var raw: String

    init(surface: SectionSurface, defaults: UserDefaults = .standard) {
        key = HeroWarmStartCache.storageKey(surface)
        self.defaults = defaults
        raw = defaults.string(forKey: key) ?? ""
    }

    func backdropURL(hero: HomeSectionRef?, catalogScope: String) -> URL? {
        HeroWarmStartCache.backdropURL(from: raw, hero: hero, catalogScope: catalogScope)
    }

    func remember(_ backdropURL: URL?, hero: HomeSectionRef?, catalogScope: String) {
        guard let backdropURL, let hero,
              let encoded = HeroWarmStartCache.encode(
                  hero: hero,
                  catalogScope: catalogScope,
                  backdropURL: backdropURL
              ),
              encoded != raw
        else { return }
        raw = encoded
        defaults.set(encoded, forKey: key)
    }
}
