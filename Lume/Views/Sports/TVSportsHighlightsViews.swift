//
//  TVSportsHighlightsViews.swift
//  Lume
//
//  "Big this week" on the tvOS hub: a rail of tall cards, each naming why it
//  made the list ("Final", "Derby", "1st v 3rd"), and — for a profile that
//  follows little or nothing — a headline for the biggest of them, with Watch
//  when it's on, Remind me before, and a way to follow its competition.
//

#if os(tvOS)

    import SwiftUI

    // MARK: - Rail

    struct TVSportsHighlightsSection: View {
        let highlights: [SportsHighlight]
        var payPerView: [SportsPayPerView.Event] = []
        let availability: (SportsFixture) -> SportsChannelAvailability
        let onSelect: (SportsFixture) -> Void
        var onWatchEvent: (SportsPayPerView.Event) -> Void = { _ in }
        /// Left from the row's first card: the hub opens its browse panel, as
        /// from every other row.
        var onLeadingLeft: (() -> Void)?

        private var firstID: String? {
            highlights.first?.id ?? payPerView.first?.id
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                SportsSectionHeading(title: Text("Big This Week"), style: .rail)
                    .padding(.horizontal, TVSportsMetrics.railInset)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: TVSportsMetrics.tallRailSpacing) {
                        ForEach(highlights) { highlight in
                            Button {
                                onSelect(highlight.fixture)
                            } label: {
                                TVHighlightCard(highlight: highlight, availability: availability(highlight.fixture))
                            }
                            .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
                            .onLeadingEdgeLeft(highlight.id == firstID ? onLeadingLeft : nil)
                        }
                        // Pay-per-view and event channels: straight to the channel,
                        // there's no match centre behind a guide listing.
                        ForEach(payPerView) { event in
                            Button {
                                onWatchEvent(event)
                            } label: {
                                TVPayPerViewCard(event: event)
                            }
                            .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
                            .onLeadingEdgeLeft(event.id == firstID ? onLeadingLeft : nil)
                        }
                    }
                    .padding(.horizontal, TVSportsMetrics.railInset)
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    private struct TVHighlightCard: View {
        let highlight: SportsHighlight
        let availability: SportsChannelAvailability

        private var fixture: SportsFixture {
            highlight.fixture
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SportsHighlightChip(title: Text(verbatim: highlight.chip), style: .television)
                        .fixedSize()
                    Spacer(minLength: 8)
                    // When, on the top line: a long title or channel name
                    // can't push it off the card.
                    Text(verbatim: whenLine)
                        .font(.system(size: 21, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 16)
                if let home = fixture.home, let away = fixture.away {
                    HStack(spacing: 14) {
                        TeamCrest(team: home.team, size: 64)
                        TeamCrest(team: away.team, size: 64)
                    }
                    .padding(.bottom, 14)
                }
                Text(verbatim: fixture.eventShortTitleOrMatchup)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(verbatim: fixture.leagueName)
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .padding(.top, 6)
                if let label = availability.label {
                    Label { Text(verbatim: label).lineLimit(1) } icon: { Image(systemName: "tv") }
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(availability.isAvailable ? Color.lumeAccent : .white.opacity(0.55))
                        .padding(.top, 10)
                }
            }
            .sportsHighlightCardSurface { backdrop }
        }

        private var whenLine: String {
            fixture.isInProgress ? String(localized: "Live now") : fixture.cardWhenText
        }

        private var backdrop: some View {
            ZStack {
                SportsArtworkBackdrop(fixture: fixture, size: .card)
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private struct TVPayPerViewCard: View {
        let event: SportsPayPerView.Event

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SportsHighlightChip(title: Text("Pay-per-view"), style: .television)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Text(verbatim: event.whenText(now: Date()))
                        .font(.system(size: 21, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 16)
                if let logoURL = event.logoURL {
                    CachedAsyncImage(url: logoURL, maxPixelSize: 160) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 120, height: 64, alignment: .leading)
                    .padding(.bottom, 14)
                }
                Text(verbatim: event.title)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                // Play only once it's on; before, the card says when.
                SportsPayPerViewChannelLabel(event: event)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.lumeAccent)
                    .padding(.top, 10)
            }
            .sportsHighlightCardSurface { SportsPayPerViewBackdrop() }
        }
    }

    // MARK: - Headline (few follows)

    struct TVSportsHighlightHero: View {
        let highlight: SportsHighlight
        let availability: SportsChannelAvailability
        let onWatch: (ResolvedChannel) -> Void
        let onOpen: () -> Void
        @State private var follows = SportsFollowService.shared

        private var fixture: SportsFixture {
            highlight.fixture
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    SportsHighlightChip(title: Text("Biggest This Week"), style: .headline)
                    Text(verbatim: "\(fixture.leagueName) · \(highlight.chip)")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(verbatim: fixture.eventShortTitleOrMatchup)
                    .font(.system(size: 68, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(verbatim: fixture.isInProgress ? String(localized: "Live now") : fixture.cardWhenText)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.8))
                actions
            }
            .foregroundStyle(.white)
            .padding(.horizontal, TVSportsMetrics.railInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }

        private var actions: some View {
            HStack(spacing: 24) {
                if fixture.isInProgress, case let .available(_, best) = availability {
                    Button { onWatch(best) } label: {
                        Label { Text("Watch on \(best.stream.name)").lineLimit(1) } icon: { Image(systemName: "play.fill") }
                            .font(.system(size: 28, weight: .bold))
                            .padding(.horizontal, 36)
                    }
                    .buttonStyle(TVGlassButtonStyle())
                    .frame(width: 640)
                } else if fixture.status.state == .scheduled {
                    SportsReminderButton(fixture: fixture) { label in
                        label
                            .font(.system(size: 28, weight: .bold))
                            .padding(.horizontal, 36)
                    }
                    .buttonStyle(TVGlassButtonStyle())
                    .frame(width: 400)
                }
                let following = follows.isFollowing(fixture.leagueId)
                Button { follows.toggle(fixture.leagueId, kind: .league) } label: {
                    Label(following ? "Following" : "Follow \(fixture.leagueName)", systemImage: following ? "star.fill" : "star")
                        .font(.system(size: 26, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 30)
                }
                .buttonStyle(TVGlassButtonStyle())
                .frame(width: 440)
                Button(action: onOpen) {
                    Text("Match Centre")
                        .font(.system(size: 26, weight: .semibold))
                        .padding(.horizontal, 30)
                }
                .buttonStyle(TVGlassButtonStyle())
                .frame(width: 300)
            }
        }
    }

#endif
