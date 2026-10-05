//
//  SportsPresentation.swift
//  Lume
//
//  Shared marks and surfaces only. Navigation, playback, hero selection and
//  focus bindings stay with the screen/button that owns those interactions.
//

import SwiftUI

enum SportsPresentationCopy {
    static let followTeams: LocalizedStringResource = "Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game."
}

struct SportsHighlightChip: View {
    enum Style {
        case compact, television, headline

        var font: Font {
            switch self {
            case .compact: .caption.weight(.heavy)
            case .television: .system(size: 19, weight: .heavy)
            case .headline: .system(size: 20, weight: .heavy)
            }
        }
    }

    let title: Text
    var style: Style = .compact

    var body: some View {
        title
            .font(style.font)
            .padding(.horizontal, style == .compact ? 8 : 14)
            .padding(.vertical, style == .compact ? 3 : 6)
            .background(Capsule().fill(.white))
            .foregroundStyle(.black)
    }
}

struct SportsReminderLabel: View {
    let isReminded: Bool

    var body: some View {
        Label(isReminded ? "Reminder Set" : "Remind Me", systemImage: isReminded ? "bell.fill" : "bell")
    }
}

/// The label's dimensions and the enclosing button's focus/style are supplied
/// by its host. Reminder persistence and kickoff-alert semantics are unchanged.
struct SportsReminderButton<Content: View>: View {
    let fixture: SportsFixture
    @ViewBuilder var label: (SportsReminderLabel) -> Content
    @State private var reminders = SportsReminders.shared

    var body: some View {
        Button { reminders.toggle(fixture) } label: {
            label(SportsReminderLabel(isReminded: reminders.isReminded(fixture.id)))
        }
    }
}

struct SportsPayPerViewBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.32, green: 0.08, blue: 0.12), Color(red: 0.08, green: 0.04, blue: 0.1)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

struct SportsPayPerViewChannelLabel: View {
    let event: SportsPayPerView.Event
    var now = Date()

    var body: some View {
        Label { Text(verbatim: event.channelName).lineLimit(1) } icon: {
            Image(systemName: event.actionSymbol(at: now))
        }
    }
}

/// A heading label, never the navigation button or focus target. Group lists
/// keep their rule/chevron; rails keep their quieter Home-aligned typography.
struct SportsSectionHeading: View {
    enum Style { case list, rail }

    let title: Text
    var logoURL: URL?
    var chevron = false
    var style: Style = .list

    var body: some View {
        if style == .list {
            label
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.separator).frame(height: 1).offset(y: 6)
                }
                .padding(.bottom, 6)
                .contentShape(Rectangle())
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: style == .list ? 8 : 10) {
            if let logoURL {
                CachedAsyncImage(url: logoURL, maxPixelSize: style == .list ? 24 : 40) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: style == .list ? 20 : 22, height: style == .list ? 20 : 22)
                .accessibilityHidden(true)
            }
            title
                .font(PosterCardMetrics.railTitleFont)
                .foregroundStyle(style == .list ? .primary : .secondary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if style == .list { Spacer() }
        }
    }
}

struct SportsNoGamesView: View {
    enum Presentation { case inline, category, screen }
    var presentation: Presentation = .inline

    var body: some View {
        if presentation == .screen {
            VStack(spacing: 24) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No games")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 560)
        } else if presentation == .category {
            Text("No games")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 24)
        } else {
            Text("No games")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }
}

/// Whole-page onboarding/locked content. tvOS deliberately keeps its large
/// action target; standard platforms retain the native unavailable container.
struct SportsUnavailableState<Action: View>: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    @ViewBuilder var action: () -> Action

    var body: some View {
        #if os(tvOS)
            VStack(spacing: 24) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 820)
                action()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
            ContentUnavailableView {
                Label { Text(title) } icon: { Image(systemName: "sportscourt") }
            } description: {
                Text(message)
            } actions: {
                action()
            }
        #endif
    }
}

private struct SportsHighlightCardSurface<Backdrop: View>: ViewModifier {
    @ViewBuilder var backdrop: () -> Backdrop

    func body(content: Content) -> some View {
        #if os(tvOS)
            content
                .foregroundStyle(.white)
                .padding(26)
                .frame(width: TVSportsMetrics.fixtureCardWidth, height: TVSportsMetrics.highlightCardHeight, alignment: .topLeading)
                .tvSportsCardSurface(cornerRadius: 30, restingOpacity: 0.08, backdrop: backdrop)
        #else
            content
                .foregroundStyle(.white)
                .padding(12)
                .frame(width: 220, height: 190, alignment: .topLeading)
                .background { backdrop().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
                .accessibilityElement(children: .combine)
        #endif
    }
}

extension View {
    func sportsHighlightCardSurface(@ViewBuilder backdrop: @escaping () -> some View) -> some View {
        modifier(SportsHighlightCardSurface(backdrop: backdrop))
    }
}

#if os(tvOS)
    private struct TVSportsCardSurface<Backdrop: View>: ViewModifier {
        let cornerRadius: CGFloat
        let restingOpacity: Double
        @ViewBuilder var backdrop: () -> Backdrop
        @Environment(\.isFocused) private var isFocused

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(backdrop())
                .overlay(shape.strokeBorder(.white.opacity(isFocused ? 1 : restingOpacity), lineWidth: isFocused ? 4 : 1))
                .clipShape(shape)
        }
    }

    extension View {
        func tvSportsStateActionLabel() -> some View {
            font(.title3.weight(.semibold))
                .padding(.horizontal, TVSportsMetrics.actionLabelInset)
                .padding(.vertical, 20)
        }

        func tvSportsCardSurface(
            cornerRadius: CGFloat,
            restingOpacity: Double = 0.1,
            @ViewBuilder backdrop: @escaping () -> some View
        ) -> some View {
            modifier(TVSportsCardSurface(cornerRadius: cornerRadius, restingOpacity: restingOpacity, backdrop: backdrop))
        }
    }
#endif
