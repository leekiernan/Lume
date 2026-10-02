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
        let availability: (SportsFixture) -> SportsChannelAvailability
        let onSelect: (SportsFixture) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Big This Week")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 60)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 32) {
                        ForEach(highlights) { highlight in
                            Button {
                                onSelect(highlight.fixture)
                            } label: {
                                TVHighlightCard(highlight: highlight, availability: availability(highlight.fixture))
                            }
                            .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
                        }
                    }
                    .padding(.horizontal, 60)
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
        @Environment(\.isFocused) private var isFocused

        private var fixture: SportsFixture {
            highlight.fixture
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: highlight.reason.chip)
                        .font(.system(size: 19, weight: .heavy))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                    Spacer(minLength: 8)
                    Text(verbatim: fixture.leagueName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
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
                Text(verbatim: whenLine)
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 6)
                if let label = availability.label {
                    Label(label, systemImage: "tv")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(availability.isAvailable ? Color.lumeAccent : .white.opacity(0.55))
                        .padding(.top, 10)
                }
            }
            .foregroundStyle(.white)
            .padding(26)
            .frame(width: 404, height: 400, alignment: .topLeading)
            .background(backdrop)
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 1 : 0.08), lineWidth: isFocused ? 4 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
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

    // MARK: - Headline (few follows)

    struct TVSportsHighlightHero: View {
        let highlight: SportsHighlight
        let availability: SportsChannelAvailability
        let onWatch: (ResolvedChannel) -> Void
        let onOpen: () -> Void
        @State private var reminders = SportsReminders.shared
        @State private var follows = SportsFollowService.shared

        private var fixture: SportsFixture {
            highlight.fixture
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Text("Biggest This Week")
                        .font(.system(size: 20, weight: .heavy))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                    Text(verbatim: "\(fixture.leagueName) · \(highlight.reason.chip)")
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
            .padding(.horizontal, 60)
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
                    let reminded = reminders.isReminded(fixture.id)
                    Button { reminders.toggle(fixture) } label: {
                        Label(reminded ? "Reminder Set" : "Remind Me", systemImage: reminded ? "bell.fill" : "bell")
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
