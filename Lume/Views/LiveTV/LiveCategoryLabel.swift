//
//  LiveCategoryLabel.swift
//  Lume
//
//  The category a channel belongs to, shown above its name where channels from
//  different categories share one list: Recently Watched and Favorites, in the
//  list and in the guide, and search results. Inside a category it would only repeat the
//  heading, so category views don't show it.
//
//  Each category keeps one colour, derived from its name, so a mixed list
//  reads at a glance: every Sport channel orange, every News channel teal —
//  on every launch and every device.
//

import SwiftData
import SwiftUI

extension LiveChannelScope {
    /// Whether channels in this list carry their category's name: the
    /// collections that mix categories.
    var showsCategoryLabels: Bool {
        switch self {
        case .category: false
        case .favorites, .recentlyWatched: true
        }
    }
}

enum LiveCategoryNames {
    /// The names of the categories `streams` belong to, keyed by category id,
    /// in one fetch of just those categories.
    static func names(for streams: [LiveStream], in context: ModelContext) -> [String: String] {
        let ids = Set(streams.compactMap(\.categoryId))
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Category>(predicate: #Predicate { ids.contains($0.id) })
        let categories = (try? context.fetch(descriptor)) ?? []
        return Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

/// A category's name, small and in its own colour, for above a channel name.
struct LiveCategoryLabel: View {
    let name: String
    /// On a light fill — a focused tvOS guide cell — where the colours lose
    /// contrast; the label goes dark instead.
    var onLight = false

    var body: some View {
        Text(name)
            .font(font)
            .textCase(.uppercase)
            .foregroundStyle(onLight ? AnyShapeStyle(.black.opacity(0.6)) : AnyShapeStyle(Self.tint(for: name)))
            .lineLimit(1)
    }

    private var font: Font {
        #if os(tvOS)
            .system(size: 18, weight: .semibold)
        #else
            .caption2.weight(.semibold)
        #endif
    }

    /// Colours that read on the dark player-style surfaces and on iOS's light
    /// and dark backgrounds alike. Not `Color.accentColor`: it is white on tvOS.
    private static let palette: [Color] = [.orange, .teal, .pink, .purple, .green, .blue, .indigo, .red, .cyan, .mint]

    /// The same colour for a name everywhere. `hashValue` is seeded per
    /// launch, so the index comes from a fixed hash of the name instead.
    static func tint(for name: String) -> Color {
        var hash: UInt64 = 5381
        for scalar in name.lowercased().unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
