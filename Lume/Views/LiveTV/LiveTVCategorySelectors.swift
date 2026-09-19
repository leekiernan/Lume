//
//  LiveTVCategorySelectors.swift
//  Lume
//
//  The Liquid Glass browse panel used to select a Live TV collection. It
//  mirrors LibraryBrowseSidebar while retaining Live TV's virtual sections.
//

import SwiftUI

struct LiveTVBrowseSidebar: View {
    @Binding var isPresented: Bool
    let sections: [LiveTVSection]
    let selectedSection: LiveTVSection?
    let onSelect: (LiveTVSection) -> Void
    /// Hands focus back to the channel the viewer came from — see
    /// `LiveTVView.returnFromBrowse`.
    var onReturnToContent: (() -> Void)?

    #if os(tvOS)
        @FocusState private var focusedSectionID: String?
        /// The row the panel was last left on, so reopening returns there.
        @State private var lastFocusedSectionID: String?
    #endif

    private var virtualSections: [LiveTVSection] {
        sections.filter(\.isVirtual)
    }

    private var categorySections: [LiveTVSection] {
        sections.filter { !$0.isVirtual }
    }

    private var margin: CGFloat {
        #if os(tvOS)
            30
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

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
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
                        ForEach(virtualSections) { section in
                            row(section)
                        }

                        if !categorySections.isEmpty {
                            Text("Categories")
                                .font(sectionLabelFont)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, contentPadding)
                                .padding(.top, virtualSections.isEmpty ? 4 : 20)
                                .padding(.bottom, 6)

                            ForEach(categorySections) { section in
                                row(section)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                #if os(tvOS)
                    .browseSidebarFocus(
                        isPresented: $isPresented,
                        focus: $focusedSectionID,
                        scrollProxy: proxy,
                        lastFocused: $lastFocusedSectionID,
                        onReturnToContent: onReturnToContent
                    ) { landingSectionID }
                #endif
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .glassEffectCompat(.regular, in: panelShape)
        .clipShape(panelShape)
        .padding(.leading, margin)
        .padding(.vertical, margin)
        #if os(tvOS)
            .focusSection()
            // States the landing target; `browseSidebarFocus` then asserts it
            // once the rows exist — declaration alone doesn't move focus here.
            .defaultFocus($focusedSectionID, landingSectionID, priority: .userInitiated)
        #endif
    }

    private var header: some View {
        HStack {
            Text("Live TV")
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

    private func row(_ section: LiveTVSection) -> some View {
        let isSelected = selectedSection?.id == section.id
        return Button {
            onSelect(section)
        } label: {
            HStack(spacing: 10) {
                if let icon = section.icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                }
                section.titleText
                    .font(rowFont)
                    .lineLimit(2)
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
        .buttonStyle(LiveTVBrowseRowButtonStyle(isSelected: isSelected))
        #if os(tvOS)
            .focused($focusedSectionID, equals: section.id)
        #endif
    }

    #if os(tvOS)
        /// Where focus lands when the panel opens: the row it was last left on,
        /// then the category being watched, then the top. Each is checked
        /// against the current list, since a category can disappear between
        /// opens.
        private var landingSectionID: String? {
            if let lastFocusedSectionID, contains(lastFocusedSectionID) {
                return lastFocusedSectionID
            }
            if let selectedSection, contains(selectedSection.id) {
                return selectedSection.id
            }
            return sections.first?.id
        }

        private func contains(_ sectionID: String) -> Bool {
            sections.contains { $0.id == sectionID }
        }
    #endif
}

private struct LiveTVBrowseRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    #if os(tvOS)
        @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
            configuration.label
                .foregroundStyle(isFocused || isSelected ? Color.white : Color.white.opacity(0.72))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(isFocused ? 0.18 : isSelected ? 0.1 : 0))
                )
        #else
            configuration.label
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : isSelected ? 0.08 : 0))
                )
        #endif
    }
}
