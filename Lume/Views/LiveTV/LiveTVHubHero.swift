import SwiftUI

/// Programme artwork when available, contained channel identity otherwise.
/// A logo is never enlarged/cropped to pretend it is a programme backdrop.
struct LiveTVHubBackdrop: View {
    let programme: LiveTVHubProgramme?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LumeAmbientBackground(style: .hero)
            if let url = programme?.artworkURL.flatMap(URL.init(string:)) {
                HeroArtworkImage(url: url)
            } else {
                CachedAsyncImage(url: programme?.channel.logoURL.flatMap(URL.init(string:)), maxPixelSize: 400) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                }
                #if os(tvOS)
                .frame(width: 320, height: 220).padding(100)
                #else
                .frame(width: 140, height: 100).padding(24)
                #endif
            }
        }
    }
}

/// The programme copy/actions, shared by the native standard carousel and the
/// tvOS showcase. Channel identity remains visible even with programme artwork.
struct LiveTVHubHeroInfo: View {
    let programme: LiveTVHubProgramme
    let now: Date
    var isCompact = false
    let onPlay: () -> Void
    let onInfo: () -> Void
    var onPage: ((Int) -> Void)?

    private var isTV: Bool {
        #if os(tvOS)
            true
        #else
            false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isTV ? 22 : 10) {
            Text(programme.isLive(at: now) ? "On Now" : "Upcoming")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.lumeAccent)
            Text(programme.title)
                .font(isTV ? .system(size: 64, weight: .bold) : .title.weight(.bold))
                .lineLimit(2)
                .frame(height: isTV ? 152 : nil, alignment: .bottomLeading)
            HStack(spacing: 10) {
                Text(programme.channel.name).lineLimit(1)
                Text("·")
                Text(programme.start, style: .time)
                Text("–")
                Text(programme.end, style: .time)
            }
            .font(isTV ? .system(size: 26) : .subheadline)
            .foregroundStyle(.white.opacity(0.8))
            if programme.isLive(at: now) {
                ProgressView(value: programme.progress(at: now)).tint(.lumeAccent)
                    .frame(maxWidth: isTV ? 560 : 320)
            }
            if !programme.overview.isEmpty {
                Text(programme.overview)
                    .font(isTV ? .system(size: 26) : .subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            actions
        }
        .foregroundStyle(.white)
        .frame(maxWidth: isTV ? 1000 : 640, alignment: .leading)
        .padding(.horizontal, isTV ? 0 : 20)
        .padding(.bottom, isTV ? 0 : 56)
    }

    @ViewBuilder private var actions: some View {
        #if os(tvOS)
            HStack(spacing: 24) {
                if programme.isLive(at: now) {
                    TVPlayButton(title: "Watch Live", action: onPlay).frame(width: 360)
                        .onCarouselEdge(.left, onPage)
                }
                Button(action: onInfo) { Label("Details", systemImage: "info.circle") }
                    .buttonStyle(TVGlassButtonStyle()).frame(width: 280)
                    .onCarouselEdge(.left, programme.isLive(at: now) ? nil : onPage)
                    .onCarouselEdge(.right, onPage)
            }
        #else
            HStack {
                if programme.isLive(at: now) {
                    Button(action: onPlay) { Label("Watch Live", systemImage: "play.fill") }
                }
                Button(action: onInfo) { Label("Details", systemImage: "info.circle") }
            }
            .buttonStyle(.bordered).tint(.white).controlSize(.large)
        #endif
    }
}

#if os(tvOS)
    struct TVLiveTVHubPage<Rows: View>: View {
        let heroes: [LiveTVHubProgramme]
        let now: Date
        let onPlay: (LiveTVHubProgramme) -> Void
        let onInfo: (LiveTVHubProgramme) -> Void
        @ViewBuilder let rows: () -> Rows
        @State private var model = TVHeroCarouselModel<LiveTVHubProgramme>(prefetchURL: { $0.artworkURL.flatMap(URL.init(string:)) })
        @Environment(\.displayScale) private var displayScale

        var body: some View {
            TVHeroFeedLayout(hasHero: !heroes.isEmpty, onFoldChange: { model.isPaused = $0 }, backdrop: { belowFold in
                LiveTVHubBackdrop(programme: model.currentHero)
                    .id(model.currentHero?.artworkURL ?? model.currentHero?.channel.id)
                    .transition(.opacity)
                    .tvHeroBackdropTreatment(belowFold: belowFold)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        model.setArtworkGeometry(.init(width: size.width, height: size.height, displayScale: displayScale))
                    }
            }, showcase: {
                showcase
            }, rows: {
                rows()
            })
            .onChange(of: heroes, initial: true) { _, items in model.configure(items: items) }
        }

        private var showcase: some View {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                if let hero = model.displayedHero {
                    LiveTVHubHeroInfo(programme: hero, now: now, onPlay: { onPlay(hero) }, onInfo: { onInfo(hero) }, onPage: model.page)
                        .opacity(model.infoOpacity)
                }
                TVHeroPageDots(model: model)
                    .frame(maxWidth: .infinity).padding(.top, 36).padding(.bottom, 24)
            }
            .padding(.horizontal)
            .containerRelativeFrame(.vertical, alignment: .topLeading) { length, _ in max(length - TVHomeMetrics.rowPeek, 0) }
            .focusSection()
            .task(id: model.items.map(\.id)) { await model.runAutoAdvance() }
        }
    }
#endif
