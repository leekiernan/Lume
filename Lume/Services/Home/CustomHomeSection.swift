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
        ProfileScopedPreferences.key(baseStorageKey(surface))
    }

    /// The unscoped form — see `HomeLayoutSettings.baseSectionOrderKey`.
    static func baseStorageKey(_ surface: SectionSurface) -> String {
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

    /// A value that changes whenever the sections that actually produce content
    /// change. Folded into Home's load key so editing a title alone doesn't
    /// refetch, but editing a URL (or adding/removing a row) does.
    static func contentSignature(_ sections: [CustomHomeSection]) -> String {
        sections.map { "\($0.id.uuidString):\($0.sourceURL)" }.joined(separator: "|")
    }
}
