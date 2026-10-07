//
//  BrowseSidebarPanel.swift
//  Lume
//
//  The one browse panel: Movies, Series, Live TV and Sports each describe their
//  rows and this draws them — a Liquid Glass sheet that slides in over the page,
//  styled after the Apple TV app's browse panel, sitting close to the screen
//  edge with the page still visible behind it.
//
//  Rows hand their selection back through their own action rather than
//  navigating themselves, so each screen keeps its own meaning for "pick":
//  Movies and Live TV push a category destination, Sports changes
//  the hub's scope.
//
//  On tvOS the panel is focus-driven (`browseSidebarFocus`): it takes focus when
//  it opens — on the selected row, else the row it was last left on, else the
//  first — and closes as soon as focus leaves it. Pressing right returns to the
//  content, Menu goes back up. Only Select acts; moving through the list never
//  does. Elsewhere a tap on the scrim closes it.
//

import SwiftUI

struct BrowseSidebarPanel: View {
    struct Row: Identifiable {
        /// Unique across the whole panel: it's the focus and scroll identity.
        let id: String
        let title: Text
        var systemImage: String?
        var imageURL: URL?
        var titleLineLimit = 1
        let action: () -> Void
    }

    struct Section: Identifiable {
        let id: String
        var title: LocalizedStringKey?
        /// A rule above the section, for a footer like "Manage Teams".
        var isSeparated = false
        let rows: [Row]
    }

    /// Each row must be a direct lazy-stack child. A nested section group can
    /// be unrealized below the fold, hiding its child IDs from scrollTo — the
    /// same constraint as Sports' off-screen filter container.
    private enum EntryID: Hashable {
        case separator(String), heading(String), row(String)
    }

    private enum Entry: Identifiable {
        case separator(String)
        case heading(String, LocalizedStringKey, isFirst: Bool)
        case row(Row)

        var id: EntryID {
            switch self {
            case let .separator(id): .separator(id)
            case let .heading(id, _, _): .heading(id)
            case let .row(row): .row(row.id)
            }
        }
    }

    @Binding var isPresented: Bool
    let title: Text
    let sections: [Section]
    /// The row for what the page currently shows: checked, and where focus
    /// lands when the panel opens, even if another row was last focused.
    var selectedId: String?
    /// Hands focus back to where the page had it as the panel closes. Without
    /// one, the page is left to the focus engine.
    var onReturnToContent: (() -> Void)?

    #if os(tvOS)
        @FocusState private var focusedRow: String?
        /// The row the panel was last left on, so reopening returns there. Kept
        /// here, on a view that outlives the panel's own content.
        @State private var lastFocusedRow: String?
    #endif

    // MARK: - Metrics

    private var panelWidth: CGFloat {
        #if os(tvOS)
            460
        #elseif os(macOS)
            300
        #else
            280
        #endif
    }

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

    private var imageSize: CGFloat {
        #if os(tvOS)
            40
        #else
            24
        #endif
    }

    private var iconSpacing: CGFloat {
        #if os(tvOS)
            18
        #else
            12
        #endif
    }

    /// Shared by the glass background and the clip, so the scrolling list
    /// can't spill past the rounded corners.
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .leading) {
            if isPresented {
                scrim
                panel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        #if !os(iOS)
        // Escapes the safe area so the panel hugs the display the way the
        // Apple TV browse panel does, rather than floating inside the
        // title-safe box.
        .ignoresSafeArea()
        #endif
        // On iOS the panel respects the bottom safe area supplied by TabView,
        // including its expanded/minimized navigation. Only the scrim extends
        // beyond it, so the final browse row stays visible and tappable.
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
            HStack(spacing: 12) {
                #if !os(tvOS)
                    // The panel covers the toolbar's browse button, so it
                    // carries its own: the same icon, closing it.
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close Browse"))
                #endif
                title
                    .font(headerFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            entryView(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                #if os(tvOS)
                    .browseSidebarFocus(
                        isPresented: $isPresented,
                        focus: $focusedRow,
                        scrollProxy: proxy,
                        scrollTarget: { AnyHashable(EntryID.row($0)) },
                        lastFocused: $lastFocusedRow,
                        onReturnToContent: onReturnToContent,
                        target: { landingRow }
                    )
                #endif
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .glassEffectCompat(.regular, in: panelShape)
        // Clip last: `glassEffect` paints its background in the shape but does
        // not bound the content, so rows showed through past the rounded
        // corners as they scrolled by.
        .clipShape(panelShape)
        .padding(.leading, BrowseSidebarMetrics.margin)
        .padding(.top, BrowseSidebarMetrics.topMargin)
        .padding(.bottom, BrowseSidebarMetrics.margin)
        #if os(tvOS)
            // One focus region, so the remote doesn't wander back out mid-list.
            .focusSection()
            // States the landing target; `browseSidebarFocus` then asserts it
            // once the rows exist — declaration alone doesn't move focus here.
            .defaultFocus($focusedRow, landingRow, priority: .userInitiated)
        #endif
    }

    private var entries: [Entry] {
        sections.enumerated().flatMap { index, section in
            var entries: [Entry] = []
            if section.isSeparated { entries.append(.separator(section.id)) }
            if let title = section.title { entries.append(.heading(section.id, title, isFirst: index == 0)) }
            entries.append(contentsOf: section.rows.map(Entry.row))
            return entries
        }
    }

    @ViewBuilder
    private func entryView(_ entry: Entry) -> some View {
        switch entry {
        case .separator:
            Divider()
                .padding(.horizontal, contentPadding)
                .padding(.vertical, 12)
        case let .heading(_, title, isFirst):
            Text(title)
                .font(sectionLabelFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, contentPadding)
                .padding(.top, isFirst ? 4 : 20)
                .padding(.bottom, 6)
        case let .row(row):
            rowView(row)
        }
    }

    /// One full-width row. Full width matters on tvOS: a narrow target won't
    /// catch "down" from the row above (see CLAUDE.md).
    private func rowView(_ row: Row) -> some View {
        let isSelected = row.id == selectedId
        return Button(action: row.action) {
            HStack(spacing: iconSpacing) {
                if let systemImage = row.systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        // A column wide enough to align ordinary symbols; a
                        // wide one (two figures and a badge) widens its own
                        // row rather than running into the title.
                        .frame(minWidth: imageSize)
                        .fixedSize()
                } else if let imageURL = row.imageURL {
                    CachedAsyncImage(url: imageURL, maxPixelSize: 64) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: imageSize, height: imageSize)
                    .accessibilityHidden(true)
                }
                row.title
                    .font(rowFont)
                    .lineLimit(row.titleLineLimit)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, contentPadding)
            .padding(.vertical, rowVerticalPadding)
        }
        .buttonStyle(BrowseSidebarRowButtonStyle(isSelected: isSelected, dimsAtRest: selectedId != nil))
        #if os(tvOS)
            .focused($focusedRow, equals: row.id)
        #endif
    }

    #if os(tvOS)
        /// The selected row, then the row last left on, then the top — each
        /// checked against the current rows, which can change between opens.
        private var landingRow: String? {
            BrowseSidebarFocusPolicy.landingID(selectedID: selectedId, lastFocusedID: lastFocusedRow,
                                               availableIDs: sections.flatMap(\.rows).map(\.id))
        }
    #endif
}

/// Quiet row treatment: the label carries the emphasis; a fill appears under
/// focus or press, and the selected row takes the redesign's selection (Lume
/// pink on a pink tint). Where a row is selected the others step back; a list
/// with no selection stays at full strength.
private struct BrowseSidebarRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    let dimsAtRest: Bool

    #if os(tvOS)
        @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
            configuration.label
                .foregroundStyle(tvForeground)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tvFill)
                )
        #else
            configuration.label
                .foregroundStyle(isSelected ? Color.lumeAccent : !dimsAtRest ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed ? Color.primary.opacity(0.12)
                            : isSelected ? Color.lumeSelection : .clear)
                )
        #endif
    }

    #if os(tvOS)
        private var tvForeground: Color {
            if isFocused { return .white }
            if isSelected { return .lumeAccent }
            return dimsAtRest ? .white.opacity(0.72) : .white
        }

        private var tvFill: Color {
            if isFocused { return .white.opacity(0.18) }
            return isSelected ? Color.lumeSelection : .clear
        }
    #endif
}
