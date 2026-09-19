//
//  LibraryBrowseSidebar.swift
//  Lume
//
//  The provider's own categories, demoted from the Movies/Series landing screen
//  to a sidebar that slides in over it. Hidden by default: the configurable
//  rows (`LibrarySectionsView`) are the page now, and this is how you reach the
//  raw catalog.
//
//  Styled after the Apple TV app's browse panel — a Liquid Glass sheet above
//  the page content, sitting close to the screen edge with the page still
//  visible behind it. Picking a category doesn't filter the page behind: it
//  navigates to that category's own full grid, which is why the rows hand their
//  selection back to the caller rather than pushing themselves.
//
//  On tvOS the panel is focus-driven: it takes focus when it opens, and closes
//  as soon as focus leaves it — pressing right returns to the content, Menu
//  goes back up. Only Select navigates; moving through the list never does.
//

import SwiftUI

struct LibraryBrowseSidebar: View {
    @Binding var isPresented: Bool
    let categories: [Category]
    let genres: [String]
    let type: CategoryType
    let onSelectCategory: (Category) -> Void
    let onSelectGenre: (String) -> Void

    #if os(tvOS)
        /// One entry in the panel, so focus can be tracked across both lists.
        private enum Item: Hashable {
            case category(String)
            case genre(String)
        }

        @FocusState private var focusedItem: Item?
        /// The row the panel was last left on, so reopening returns there.
        @State private var lastFocusedItem: Item?
    #endif

    /// Margin from the screen edge. The panel deliberately escapes the safe
    /// area (`ignoresSafeArea` below) so it hugs the display the way the Apple
    /// TV browse panel does, rather than floating inside the title-safe box.
    private var margin: CGFloat {
        #if os(tvOS)
            30
        #else
            12
        #endif
    }

    /// tvOS body text runs large by default; the panel is a dense list, so it
    /// steps down a little. Other platforms keep their system sizes.
    private var rowFont: Font {
        #if os(tvOS)
            .system(size: 24)
        #else
            .body
        #endif
    }

    private var headerFont: Font {
        #if os(tvOS)
            .system(size: 26, weight: .semibold)
        #else
            .headline
        #endif
    }

    private var sectionLabelFont: Font {
        #if os(tvOS)
            .system(size: 18, weight: .semibold)
        #else
            .footnote.weight(.semibold)
        #endif
    }

    /// The panel's outline. Shared by the glass background and the clip, so the
    /// scrolling list can't spill past the rounded corners.
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
    }

    /// Inset from the panel's own edges to its content.
    private var contentPadding: CGFloat {
        #if os(tvOS)
            28
        #else
            20
        #endif
    }

    private var rowVerticalPadding: CGFloat {
        #if os(tvOS)
            14
        #else
            12
        #endif
    }

    private var panelWidth: CGFloat {
        #if os(tvOS)
            460
        #elseif os(macOS)
            300
        #else
            280
        #endif
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if isPresented {
                scrim
                panel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.28), value: isPresented)
    }

    private var scrim: some View {
        Rectangle()
            .fill(.black.opacity(0.35))
            .ignoresSafeArea()
        // tvOS has no pointer to dismiss with — Menu and focus do it instead.
        #if !os(tvOS)
            .onTapGesture { isPresented = false }
        #endif
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(categories) { category in
                            row(name: category.name, id: category.id, isGenre: false) {
                                onSelectCategory(category)
                            }
                        }

                        if !genres.isEmpty {
                            Text("Browse by Genre")
                                .font(sectionLabelFont)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, contentPadding)
                                .padding(.top, 20)
                                .padding(.bottom, 6)

                            ForEach(genres, id: \.self) { genre in
                                row(name: genre, id: genre, isGenre: true) {
                                    onSelectGenre(genre)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                #if os(tvOS)
                    .browseSidebarFocus(
                        isPresented: $isPresented,
                        focus: $focusedItem,
                        scrollProxy: proxy,
                        lastFocused: $lastFocusedItem
                    ) { landingItem }
                #endif
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .glassEffectCompat(.regular, in: panelShape)
        // Clip last: `glassEffect` paints its background in the shape but does
        // not bound the content, so the scrolling rows showed through past the
        // rounded corners as they passed the top and bottom edges.
        .clipShape(panelShape)
        .padding(.leading, margin)
        .padding(.vertical, margin)
        #if os(tvOS)
            // One focus region, so the remote doesn't wander back out mid-list.
            .focusSection()
            // States the landing target; `browseSidebarFocus` then asserts it
            // once the rows exist — declaration alone doesn't move focus here.
            .defaultFocus($focusedItem, landingItem, priority: .userInitiated)
        #endif
    }

    private var header: some View {
        HStack {
            // The app's own term for the type, so the panel header matches the
            // tab, Content Management and everywhere else.
            Text(type.localizedLabel)
                .font(headerFont)

            Spacer(minLength: 0)

            #if !os(tvOS)
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
            #endif
        }
        .padding(.horizontal, contentPadding)
        .padding(.top, contentPadding)
        .padding(.bottom, 12)
    }

    /// One full-width row. Full width matters on tvOS: a narrow target won't
    /// catch "down" from the row above (see CLAUDE.md).
    private func row(name: String, id: String, isGenre: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: name)
                    .font(rowFont)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, contentPadding)
            .padding(.vertical, rowVerticalPadding)
        }
        .buttonStyle(LibraryBrowseRowButtonStyle())
        #if os(tvOS)
            .focused($focusedItem, equals: isGenre ? .genre(id) : .category(id))
            // Same value as the scroll id, so `landTVFocus` can bring a row
            // below the fold on screen before asking for focus.
            .id(isGenre ? Item.genre(id) : Item.category(id))
        #endif
    }

    #if os(tvOS)
        /// Where focus lands when the panel opens: the row it was last left on,
        /// then the top. The remembered row is checked against the current
        /// lists, since either can change between opens.
        private var landingItem: Item? {
            if let lastFocusedItem, contains(lastFocusedItem) { return lastFocusedItem }
            return firstItem
        }

        private var firstItem: Item? {
            if let first = categories.first { return .category(first.id) }
            if let genre = genres.first { return .genre(genre) }
            return nil
        }

        private func contains(_ item: Item) -> Bool {
            switch item {
            case let .category(id): categories.contains { $0.id == id }
            case let .genre(name): genres.contains(name)
            }
        }
    #endif
}

/// Quiet row treatment: the label carries the emphasis, the background only
/// appears under press or focus.
private struct LibraryBrowseRowButtonStyle: ButtonStyle {
    #if os(tvOS)
        @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(isFocused ? 0.18 : 0))
                )
        #else
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
                )
        #endif
    }
}
