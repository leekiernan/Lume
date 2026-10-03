//
//  ContentRestrictionProvider.swift
//  Lume
//
//  Derives `ContentRestriction` from the catalog and injects it, for scenes that
//  do not inherit `MainTabView`'s environment. The macOS player is its own
//  `WindowGroup`, so without this it resolves the permissive `@Entry` default
//  and a child profile can surf into a category a parent locked.
//
//  Each scene owns its queries, but ContentRestrictionMemo shares the policy
//  and ID normalization with MainTabView so the two cannot drift.
//

import SwiftData
import SwiftUI

struct ContentRestrictionProvider<Content: View>: View {
    // Optional so previews (which don't inject it) don't crash.
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query(filter: #Predicate<Category> { $0.isRestricted }) private var restrictedCategories: [Category]
    @Query(filter: #Predicate<Category> { $0.isHidden }) private var hiddenCategories: [Category]

    /// See `ContentRestrictionMemo` — building a restriction digests every
    /// excluded id, and this body re-runs on every catalog write.
    @State private var restrictionMemo = ContentRestrictionMemo()

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var contentRestriction: ContentRestriction {
        restrictionMemo.restriction(
            isChild: profileManager?.activeProfileIsChild,
            restrictedIDs: restrictedCategories.map(\.id),
            hiddenIDs: hiddenCategories.map(\.id)
        )
    }

    var body: some View {
        content
            .environment(\.contentRestriction, contentRestriction)
    }
}
