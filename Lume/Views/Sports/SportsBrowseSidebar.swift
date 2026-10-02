//
//  SportsBrowseSidebar.swift
//  Lume
//
//  The Sports hub's scope — My Teams or one followed league — picked from the
//  same Liquid Glass browse panel Movies, Series and Live TV use, rather than a
//  title menu. On tvOS it slides in on a left press from the page's leading
//  edge and follows `browseSidebarFocus`; elsewhere a toolbar button opens it.
//

import SwiftUI

struct SportsBrowseSidebar: View {
    @Binding var isPresented: Bool
    let leagues: [SportsLeague]
    let scope: SportsHubScope
    let onSelect: (SportsHubScope) -> Void
    let onManageTeams: () -> Void
    /// Hands focus back to where the page had it.
    var onReturnToContent: (() -> Void)?

    #if os(tvOS)
        @FocusState private var focusedRow: String?
        @State private var lastFocusedRow: String?
    #endif

    private static let myTeamsRow = "myTeams"
    private static let manageRow = "manage"

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

    private var logoSize: CGFloat {
        #if os(tvOS)
            32
        #else
            22
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
            Text("Sports")
                .font(headerFont)
                .padding(.horizontal, contentPadding)
                .padding(.top, contentPadding)
                .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        row(id: Self.myTeamsRow, isSelected: scope == .myTeams, action: { onSelect(.myTeams) }, label: {
                            Image(systemName: "star.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: logoSize)
                            Text("My Teams")
                        })

                        if !leagues.isEmpty {
                            Text("Leagues")
                                .font(sectionLabelFont)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, contentPadding)
                                .padding(.top, 20)
                                .padding(.bottom, 6)
                            ForEach(leagues) { league in
                                row(id: league.id, isSelected: scope == .league(league.id), action: { onSelect(.league(league.id)) }, label: {
                                    leagueLogo(league)
                                    Text(verbatim: league.name)
                                })
                            }
                        }

                        Divider()
                            .padding(.horizontal, contentPadding)
                            .padding(.vertical, 12)
                        row(id: Self.manageRow, isSelected: false, action: onManageTeams, label: {
                            Image(systemName: "person.2.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: logoSize)
                            Text("Manage Teams")
                        })
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                #if os(tvOS)
                    .browseSidebarFocus(
                        isPresented: $isPresented,
                        focus: $focusedRow,
                        scrollProxy: proxy,
                        lastFocused: $lastFocusedRow,
                        onReturnToContent: onReturnToContent
                    ) { landingRow }
                #endif
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .glassEffectCompat(.regular, in: panelShape)
        .clipShape(panelShape)
        .padding(.leading, BrowseSidebarMetrics.margin)
        .padding(.top, BrowseSidebarMetrics.topMargin)
        .padding(.bottom, BrowseSidebarMetrics.margin)
        #if os(tvOS)
            .focusSection()
            .defaultFocus($focusedRow, landingRow, priority: .userInitiated)
        #endif
    }

    private func leagueLogo(_ league: SportsLeague) -> some View {
        CachedAsyncImage(url: league.logoURL, maxPixelSize: 64) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: logoSize, height: logoSize)
        .accessibilityHidden(true)
    }

    /// One full-width row — a narrow target won't catch "down" on tvOS.
    private func row(
        id: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                label()
                    .font(rowFont)
                    .lineLimit(1)
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
        .buttonStyle(SportsBrowseRowButtonStyle(isSelected: isSelected))
        #if os(tvOS)
            .focused($focusedRow, equals: id)
            .id(id)
        #endif
    }

    #if os(tvOS)
        /// The row last left on, then the current scope, then My Teams.
        private var landingRow: String? {
            if let lastFocusedRow, lastFocusedRow == Self.myTeamsRow || lastFocusedRow == Self.manageRow
                || leagues.contains(where: { $0.id == lastFocusedRow })
            {
                return lastFocusedRow
            }
            if case let .league(id) = scope, leagues.contains(where: { $0.id == id }) { return id }
            return Self.myTeamsRow
        }
    #endif
}

/// The Live TV panel's row treatment: the selected row keeps a faint fill.
private struct SportsBrowseRowButtonStyle: ButtonStyle {
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
