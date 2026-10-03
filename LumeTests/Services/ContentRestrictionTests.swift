//
//  ContentRestrictionTests.swift
//  LumeTests
//
//  Covers the content-visibility filter: categories hidden in Content
//  Management are excluded for every profile, while restricted categories (and
//  the content in them) are excluded only while a child profile is active.
//

import Foundation
@testable import Lume
import Testing

/// Minimal stand-in for a categorised content item (Movie/Series/LiveStream all
/// conform to `CategorizedContent`); lets the filter be tested without models.
private struct StubItem: CategorizedContent {
    let categoryId: String?
}

@MainActor
struct ContentRestrictionTests {
    @Test func `scene construction normalizes ids and keeps child and hidden policies independent`() {
        let memo = ContentRestrictionMemo()
        let parent = memo.restriction(isChild: nil, restrictedIDs: ["adult", "adult"], hiddenIDs: ["hidden", "hidden"])
        #expect(parent.excludedCategoryIDs == ["hidden"])
        let child = memo.restriction(isChild: true, restrictedIDs: ["adult"], hiddenIDs: ["hidden"])
        #expect(child.excludedCategoryIDs == ["adult", "hidden"])
        #expect(child.visibilityToken != parent.visibilityToken)
        let restored = memo.restriction(isChild: false, restrictedIDs: ["adult"], hiddenIDs: ["hidden"])
        #expect(restored.visibilityToken == parent.visibilityToken)
    }

    @Test func `separate scene memos derive identical restrictions`() {
        let root = ContentRestrictionMemo()
        let player = ContentRestrictionMemo()
        let expected = root.restriction(isChild: true, restrictedIDs: ["b", "a"], hiddenIDs: ["c"])
        let actual = player.restriction(isChild: true, restrictedIDs: ["a", "b", "a"], hiddenIDs: ["c", "c"])
        #expect(actual == expected)
        #expect(actual.restrictedCategoryIDs == expected.restrictedCategoryIDs)
        #expect(actual.hiddenCategoryIDs == expected.hiddenCategoryIDs)
    }

    @Test func `inactive restriction hides nothing`() {
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: ["a", "b"])
        #expect(restriction.hides(categoryID: "a") == false)
        #expect(restriction.hides(categoryID: "b") == false)
    }

    @Test func `active restriction hides only restricted categories`() {
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["a"])
        #expect(restriction.hides(categoryID: "a") == true)
        #expect(restriction.hides(categoryID: "b") == false)
    }

    @Test func `nil category is never hidden`() {
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["a"])
        #expect(restriction.hides(categoryID: nil) == false)
    }

    @Test func `excluding restricted drops matching items when active`() {
        let items = [StubItem(categoryId: "a"), StubItem(categoryId: "b"), StubItem(categoryId: nil)]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["a"])
        let kept = items.excludingRestricted(restriction)
        #expect(kept.map(\.categoryId) == ["b", nil])
    }

    @Test func `excluding restricted keeps everything for parent profile`() {
        let items = [StubItem(categoryId: "a"), StubItem(categoryId: "b")]
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: ["a"])
        #expect(items.excludingRestricted(restriction).count == 2)
    }

    @Test func `excluding restricted keeps everything when nothing restricted`() {
        let items = [StubItem(categoryId: "a"), StubItem(categoryId: "b")]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [])
        #expect(items.excludingRestricted(restriction).count == 2)
    }

    // MARK: - Content Management visibility

    @Test func `hidden categories are hidden from every profile`() {
        let restriction = ContentRestriction(isActive: false, hiddenCategoryIDs: ["nl"])
        #expect(restriction.hides(categoryID: "nl") == true)
        #expect(restriction.hides(categoryID: "en") == false)
        #expect(restriction.hides(categoryID: nil) == false)
    }

    @Test func `excluded ids combine hidden and restricted only for a child profile`() {
        let parent = ContentRestriction(
            isActive: false, restrictedCategoryIDs: ["adult"], hiddenCategoryIDs: ["nl"]
        )
        #expect(parent.excludedCategoryIDs == ["nl"])

        let child = ContentRestriction(
            isActive: true, restrictedCategoryIDs: ["adult"], hiddenCategoryIDs: ["nl"]
        )
        #expect(child.excludedCategoryIDs == ["nl", "adult"])
    }

    @Test func `excluding restricted drops hidden categories on a parent profile`() {
        let items = [StubItem(categoryId: "nl"), StubItem(categoryId: "en"), StubItem(categoryId: nil)]
        let restriction = ContentRestriction(isActive: false, hiddenCategoryIDs: ["nl"])
        #expect(items.excludingRestricted(restriction).map(\.categoryId) == ["en", nil])
    }
}
