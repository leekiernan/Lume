//
//  CustomHomeSection.swift
//  Lume
//
//  User-defined rows built from a public list URL (MDBList today, see
//  `HomeListCatalog`), on any section surface — Home, Movies or Series. Like
//  the built-in row order these are a small scalar preference, so they live in
//  UserDefaults via @AppStorage rather than in either model container — they
//  describe the *layout*, not the catalog.
//

import Foundation

/// One user-added row: a display title and the list URL it is built from.
/// The provider is derived from the URL at fetch time (`HomeListCatalog`), so a
/// section keeps working if a provider later changes how it is addressed.
nonisolated struct CustomHomeSection: Codable, Identifiable, Hashable {
    let id: UUID
    /// The section header shown on Home. User text — never localized.
    var title: String
    /// The list page URL the user pasted, stored exactly as they gave it.
    var sourceURL: String

    init(id: UUID = UUID(), title: String, sourceURL: String) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
    }

    /// The provider that will serve this section, or nil when the URL doesn't
    /// match any known one (the row then renders empty and the editor flags it).
    var provider: (any HomeListProvider)? {
        HomeListCatalog.provider(for: sourceURL)
    }
}

/// Storage for a surface's custom rows: a JSON array under one UserDefaults
/// key per surface, mirroring how `HomeLayoutSettings` keeps the row order.
/// Home, Movies and Series each keep their own list — a section added on one
/// page never appears on another.
enum CustomHomeSections {
    static func storageKey(_ surface: SectionSurface) -> String {
        "\(surface.storagePrefix).customSections.v1"
    }

    /// Upper bound on custom rows. Each one is a network fetch on every Home
    /// load, and the stored order string grows by a UUID per section.
    static let maximumCount = 20

    static func decode(_ raw: String) -> [CustomHomeSection] {
        guard let data = raw.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([CustomHomeSection].self, from: data)) ?? []
    }

    static func encode(_ sections: [CustomHomeSection]) -> String {
        guard !sections.isEmpty else { return "" }
        guard let data = try? JSONEncoder().encode(sections),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }

    /// Insert or replace `section` by id, capping the list at `maximumCount`.
    /// Returns the new list; the caller writes it back to @AppStorage.
    static func upsert(_ section: CustomHomeSection, into sections: [CustomHomeSection]) -> [CustomHomeSection] {
        var result = sections
        if let index = result.firstIndex(where: { $0.id == section.id }) {
            result[index] = section
        } else if result.count < maximumCount {
            result.append(section)
        }
        return result
    }

    static func remove(id: UUID, from sections: [CustomHomeSection]) -> [CustomHomeSection] {
        sections.filter { $0.id != id }
    }

    /// The row a surface starts life with, promoted to its hero: the trending
    /// list for that medium, as an ordinary section. Nothing about it is
    /// special — it can be edited, reordered, demoted or deleted like any other,
    /// which is the point. Hardcoding the hero's source instead left a default
    /// nobody could see or change.
    ///
    /// Returns the new sections and hero token, or nil when there is nothing to
    /// do: already seeded once, or the surface already has a hero.
    static func seedingDefaultHero(
        surface: SectionSurface,
        sections: [CustomHomeSection],
        heroRaw: String,
        orderRaw: String,
        seeded: Bool
    ) -> HeroSeeding {
        guard !seeded else { return .nothingToDo }
        // A surface that already has a working hero has had one, however it got
        // there. Recording that is what keeps a later removal removed.
        guard !heroResolves(heroRaw, sections: sections, surface: surface) else { return .alreadyHasHero }
        let section = CustomHomeSection(
            title: String(localized: "Trending", comment: "Title of the hero row each page starts with"),
            sourceURL: surface.defaultHeroSourceURL
        )
        let ref = HomeSectionRef.custom(section.id)
        let sections = upsert(section, into: sections)
        // First in the order, not appended: it is the hero, and the settings
        // list should open on it rather than bury it under every built-in row.
        let order = HomeLayoutSettings.normalized(
            [ref] + HomeLayoutSettings.decode(orderRaw), custom: sections, surface: surface
        )
        return .seed(sections: sections, heroToken: ref.token, orderRaw: HomeLayoutSettings.encode(order))
    }

    /// What, if anything, to do about a surface's starting hero.
    enum HeroSeeding {
        /// Create it: this surface has never had one.
        case seed(sections: [CustomHomeSection], heroToken: String, orderRaw: String)
        /// It already has one, by any route. The caller records that, so
        /// removing the hero later doesn't quietly bring a new one back —
        /// seeding is for first-time users, not a default that reasserts itself.
        case alreadyHasHero
        /// Seeded before, or deliberately without a hero. Leave it alone.
        case nothingToDo

        var isSeed: Bool {
            if case .seed = self { return true }
            return false
        }
    }

    /// Whether the stored hero actually names something this surface can show.
    ///
    /// An empty value is the obvious "no hero", but so is a token that no longer
    /// resolves: a value written by an older build in a different format, or a
    /// section since deleted. Treating those as "has a hero" would leave the
    /// surface with no hero *and* block the seed that would give it one.
    static func heroResolves(
        _ raw: String,
        sections: [CustomHomeSection],
        surface: SectionSurface
    ) -> Bool {
        switch HomeLayoutSettings.heroRef(raw) {
        case let .custom(id):
            sections.contains { $0.id == id }
        case let .builtin(section):
            HomeSection.cases(for: surface).contains(section) && section.isPromotable
        case nil:
            false
        }
    }

    /// A value that changes whenever the sections that actually produce content
    /// change. Folded into Home's load key so editing a title alone doesn't
    /// refetch, but editing a URL (or adding/removing a row) does.
    static func contentSignature(_ sections: [CustomHomeSection]) -> String {
        sections.map { "\($0.id.uuidString):\($0.sourceURL)" }.joined(separator: "|")
    }

    /// The Trakt account the sections' list fetches run as, for folding into the
    /// same load key. A private list's rows must not outlive a disconnect or
    /// survive a switch to another account, so the load re-runs when it
    /// changes. Empty when no section reads from Trakt, so connecting an
    /// account doesn't refetch rows it can't affect.
    static func accountSignature(_ sections: [CustomHomeSection], traktUsername: String?) -> String {
        guard sections.contains(where: { $0.provider is TraktListProvider }) else { return "" }
        return "trakt:\(traktUsername ?? "none")"
    }
}
