//
//  TVDetailComponents.swift
//  Lume
//
//  tvOS-only building blocks for the Apple TV+/App-Store-style movie and series
//  detail screens. These follow the redesign's film and series boards: a
//  full-bleed backdrop with a three-column info band (action button · title +
//  synopsis + rating · metadata key/values), then horizontal rails for
//  episodes, cast and related titles, plus an "About" / ratings block.
//
//  Everything here is tuned for the 10-foot UI and the focus engine: cards lift
//  and gain a shadow when focused, the primary Play button is the default focus,
//  and rails are wrapped in focus sections by the composing views.
//

#if os(tvOS)

    import Foundation
    import SwiftUI

    // MARK: - Star rating

    /// Five-star rating (with halves) plus the numeric value, on a 0…5 scale.
    struct TVStarRating: View {
        let rating: Double // 0...5
        var showsValue: Bool = true

        var body: some View {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0 ..< 5, id: \.self) { index in
                        Image(systemName: symbol(for: index))
                    }
                }
                .font(.system(size: 26))
                .foregroundStyle(Color.lumeAccent)

                if showsValue {
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }

        private func symbol(for index: Int) -> String {
            let position = Double(index)
            if rating >= position + 1 { return "star.fill" }
            if rating >= position + 0.5 { return "star.leadinghalf.filled" }
            return "star"
        }
    }

    // MARK: - External ratings

    /// A row of MDBList aggregator-rating chips sized for the 10-foot UI. Shows
    /// at most four chips (highest display priority first) so the row can't
    /// outgrow the About column. Renders nothing when empty.
    struct TVExternalRatingsView: View {
        let ratings: [ExternalRating]

        var body: some View {
            let displayed = ratings.sorted { $0.source.displayPriority < $1.source.displayPriority }.prefix(4)
            if !displayed.isEmpty {
                // The redesign's ratings: one surface card per source, its
                // name over a large score.
                HStack(spacing: 28) {
                    ForEach(displayed) { rating in
                        VStack(alignment: .leading, spacing: 8) {
                            // Brand names are proper nouns — never localized.
                            Text(rating.source.displayName)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color.lumeTextSecondary)
                                .lineLimit(1)
                            Text(rating.value)
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 26)
                        .background(TVDetailSurface())
                    }
                }
            }
        }
    }

    // MARK: - Badge

    /// A pill badge for the content rating or a highlight tag.
    struct TVBadge: View {
        let text: String
        var filled: Bool = false

        var body: some View {
            Text(text)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(filled ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(0.6), lineWidth: filled ? 0 : 2)
                        )
                )
        }
    }

    // MARK: - Metadata column

    struct TVMetaItem: Identifiable {
        var id: String {
            label
        }

        let label: String
        let value: String
    }

    /// The right-hand key/value column in the hero band
    /// (e.g. Released · Genre · Director).
    struct TVMetaColumn: View {
        let items: [TVMetaItem]

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        TVDetailLabel(item.label)
                        Text(item.value)
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Hero band

    /// The cinematic header: a full-bleed backdrop dimmed by a bottom gradient,
    /// with a three-column info band pinned to the lower edge. The `actions`
    /// slot holds the Play button and any secondary buttons.
    struct TVDetailHero<Actions: View>: View {
        var presentation: TVDetailMetrics.Hero = .film
        let title: String
        let backdropURL: URL?
        let posterFallbackURL: URL?
        var logoURL: URL?
        var tagline: String?
        var rating: Double? // 0...5
        var badge: String?
        let metaItems: [TVMetaItem]
        var fallbackSymbol: String = "film"
        @ViewBuilder var actions: () -> Actions

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                DetailBackdropArtwork(backdropURL: backdropURL, posterFallbackURL: posterFallbackURL, fallbackSymbol: fallbackSymbol, appearance: .television)

                // Bottom scrim into the Night ground (the detail boards': clear
                // to 60% of the way down, Night at 55% by 70%, solid at the foot).
                LinearGradient(
                    stops: [
                        .init(color: .lumeNight.opacity(0), location: 0.4),
                        .init(color: .lumeNight.opacity(0.55), location: 0.7),
                        .init(color: .lumeNight, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                HStack(alignment: .top, spacing: 56) {
                    // Action column
                    VStack(alignment: .leading, spacing: 18) {
                        actions()
                    }
                    .frame(width: 420, alignment: .leading)

                    // Title + synopsis + rating
                    VStack(alignment: .leading, spacing: 14) {
                        TitleLogo(url: logoURL, title: title, maxWidth: 820, maxHeight: 150) {
                            // The boards' display title, when there is no logo.
                            Text(title)
                                .font(.system(size: presentation.titleSize, weight: .heavy))
                                .kerning(presentation.titleKerning)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.4)
                                .shadow(radius: 10)
                        }

                        if let tagline, !tagline.isEmpty {
                            Text(tagline)
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }

                        HStack(spacing: 20) {
                            if let rating, rating > 0 {
                                TVStarRating(rating: rating)
                            }
                            if let badge, !badge.isEmpty {
                                TVBadge(text: badge)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Metadata key/values
                    if !metaItems.isEmpty {
                        TVMetaColumn(items: metaItems)
                            .frame(width: 360, alignment: .leading)
                    }
                }
                .padding(.horizontal, TVDetailMetrics.horizontalInset)
                .padding(.bottom, TVDetailMetrics.heroBottomInset)
            }
            .frame(maxWidth: .infinity)
            .frame(height: TVDetailMetrics.heroHeight)
            .clipped()
        }
    }

    // MARK: - Section header

    struct TVSectionHeader: View {
        let title: LocalizedStringKey

        var body: some View {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    /// The redesign's surface under detail cards: white 7%, 24-point corners.
    struct TVDetailSurface: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.07))
        }
    }

    /// An uppercase key above a detail value (RELEASED, GENRE, DIRECTOR…).
    struct TVDetailLabel: View {
        let key: String

        init(_ key: String) {
            self.key = key
        }

        var body: some View {
            Text(LocalizedStringKey(key)).textCase(.uppercase)
                .font(.system(size: 20, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.lumeTextSecondary)
        }
    }

    // MARK: - Episode card

    /// A large 16:9 episode card for the horizontal episode rail: still image
    /// with a resume bar, then number/title, runtime and a two-line synopsis.
    struct TVEpisodeCard: View {
        let episode: Episode
        var onPlay: () -> Void
        var onSetWatched: (Bool) -> Void = { _ in }
        var onMarkPreviousWatched: () -> Void = {}
        var onMarkFollowingUnwatched: () -> Void = {}

        var body: some View {
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 14) {
                    still
                    VStack(alignment: .leading, spacing: 6) {
                        Text(heading)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let metaLine {
                            Text(metaLine)
                                .font(.system(size: 22))
                                .foregroundStyle(Color.lumeTextSecondary)
                                .lineLimit(1)
                        }

                        if let plot = episode.plot, !plot.isEmpty {
                            Text(plot)
                                .font(.system(size: 22))
                                .foregroundStyle(Color.lumeTextTertiary)
                                .lineLimit(2)
                        }
                    }
                    .frame(width: TVDetailMetrics.episodeCardWidth, alignment: .leading)
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .contextMenu {
                EpisodeWatchedMenu(
                    episode: episode,
                    onSetWatched: onSetWatched,
                    onMarkPreviousWatched: onMarkPreviousWatched,
                    onMarkFollowingUnwatched: onMarkFollowingUnwatched
                )
            }
        }

        private var still: some View {
            ZStack(alignment: .bottom) {
                EpisodeStillArtwork(title: episode.title, url: episode.movieImage.flatMap(URL.init(string:)), maxPixelSize: 640) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: TVDetailMetrics.episodeCardWidth, height: TVDetailMetrics.episodeStillHeight)
                .clipped()

                if let progress = resumeFraction {
                    ArtworkProgressBar(fraction: progress)
                }

                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: TVDetailMetrics.episodeCardWidth, height: TVDetailMetrics.episodeStillHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }

        private var heading: String {
            episode.title.isEmpty ? String(localized: "Episode \(episode.episodeNum)") : "\(episode.episodeNum). \(episode.title)"
        }

        private var metaLine: String? {
            let parts = [
                DetailFormat.date(from: episode.airDate),
                DetailFormat.minutes(episode.durationSecs)
            ].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
        }

        private var resumeFraction: Double? {
            ContinueWatching.resumeFraction(
                progress: episode.watchProgress, duration: episode.durationSecs, isWatched: episode.isWatched
            )
        }
    }

    // MARK: - Cast card

    struct TVCastCard: View {
        let member: CastMember

        @FocusState private var isFocused: Bool

        var body: some View {
            VStack(spacing: 14) {
                CachedAsyncImage(url: TMDBClient.profileURL(member.profilePath, size: "w342"), maxPixelSize: TVDetailMetrics.castAvatar) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty where member.profilePath != nil:
                        Rectangle().fill(Color.white.opacity(0.10)).overlay { ProgressView() }
                    default:
                        Rectangle().fill(Color.white.opacity(0.10))
                            .overlay {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    }
                }
                .frame(width: TVDetailMetrics.castAvatar, height: TVDetailMetrics.castAvatar)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
                )

                VStack(spacing: 4) {
                    Text(member.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let role = member.role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 20))
                            .foregroundStyle(Color.lumeTextTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(width: TVDetailMetrics.castCardWidth)
            }
            .focusable(true)
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }

    // MARK: - Info card

    /// A card listing supplementary key/value information (Director, Genre…).
    struct TVInfoCard: View {
        let title: LocalizedStringKey
        let items: [TVMetaItem]

        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                TVSectionHeader(title: title)
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            TVDetailLabel(item.label)
                            Text(item.value)
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(32)
                .background(TVDetailSurface())
            }
        }
    }

    // MARK: - Rail helper

    /// A titled horizontal rail wrapped in a focus section so the remote moves
    /// cleanly between sections. Data-driven so the rail can bind focus to each
    /// card and land entry focus on the first item.
    struct TVRail<Item: Identifiable, Content: View>: View {
        let title: LocalizedStringKey
        let items: [Item]
        @ViewBuilder var content: (Item) -> Content

        @FocusState private var focusedItem: Item.ID?

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                TVSectionHeader(title: title)
                    .padding(.horizontal, TVDetailMetrics.horizontalInset)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVDetailMetrics.railSpacing) {
                        ForEach(items) { item in
                            content(item)
                                .focused($focusedItem, equals: item.id)
                        }
                    }
                    .padding(.horizontal, TVDetailMetrics.horizontalInset)
                    .padding(.vertical, 24) // breathing room for the focus lift
                }
                .scrollClipDisabled()
                // When focus moves INTO the rail from above/below, the enclosing
                // focus section would otherwise pick the card nearest the
                // SECTION's center — mid-rail, not the first card. `.userInitiated`
                // re-applies this default on user-driven entry, not just on
                // appearance.
                .defaultFocus($focusedItem, items.first?.id, priority: .userInitiated)
            }
            .focusSection()
        }
    }

    // MARK: - Loading

    /// Enrichment status beneath the already-usable hero. Loading must not
    /// replace the destination's actions and leave tvOS with no focus target.
    struct TVDetailLoadingStatus: View {
        var body: some View {
            HStack(spacing: 16) {
                ProgressView()

                Text("Loading details…")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, TVDetailMetrics.horizontalInset)
        }
    }

#endif
