#if !os(tvOS)

    import SwiftUI

    /// Layout settings for one section surface — Home, Movies or Series (iOS /
    /// macOS): switch each row on or off and drag to reorder them. Each row still
    /// only appears when it has something to show. Custom rows built from a list
    /// URL are added, edited and removed here too, and sit in the same order as
    /// the built-in ones. Every surface keeps its own order, hidden set and
    /// custom rows — see `SectionSurface`, `HomeLayoutSettings` and
    /// `CustomHomeSection`.
    struct SectionLayoutSettingsView: View {
        let surface: SectionSurface
        /// The area's catalog categories, when it has any. Non-nil adds the
        /// drill-in to category management; Home passes nil.
        var categoryType: CategoryType?

        /// "For You" is the opt-in recommendations row; its toggle writes the same
        /// flag that gates the recommendation recompute on Home.
        @AppStorage(RecommendationSettings.enabledKey) private var recommendationsEnabled = RecommendationSettings.enabledDefault
        @AppStorage private var sectionOrderRaw: String
        @AppStorage private var disabledSectionsRaw: String
        @AppStorage private var customSectionsRaw: String
        @AppStorage private var heroSectionRaw: String
        @AppStorage private var heroSeeded: Bool
        /// Sports is a Live TV feature (fixtures matched to EPG channels), so it
        /// only offers itself as a row when this profile has Live TV on.
        @AppStorage(AppAreaSettings.disabledAreasKey) private var disabledAreasRaw = ""
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        /// Which paywall to surface — "For You" and "Sports" are both Lume Pro
        /// features but advertise different entitlements.
        @State private var paywallHighlight: PremiumFeature = .recommendations
        @State private var editorMode: CustomHomeSectionEditor.Mode?

        /// The three stores are keyed by surface, so they're built in `init`
        /// rather than declared with a literal key.
        init(surface: SectionSurface, categoryType: CategoryType? = nil) {
            self.surface = surface
            self.categoryType = categoryType
            _sectionOrderRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.sectionOrderKey(surface))
            _disabledSectionsRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.disabledSectionsKey(surface))
            _customSectionsRaw = AppStorage(wrappedValue: "", CustomHomeSections.storageKey(surface))
            _heroSectionRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.heroSectionKey(surface))
            _heroSeeded = AppStorage(wrappedValue: false, HomeLayoutSettings.heroSeededKey(surface))
        }

        private var customSections: [CustomHomeSection] {
            CustomHomeSections.decode(customSectionsRaw)
        }

        private var sections: [HomeSectionRef] {
            HomeLayoutSettings.resolve(
                orderRaw: sectionOrderRaw, custom: customSections, surface: surface,
                liveTVEnabled: AppAreaSettings.isEnabled(.liveTV, disabledRaw: disabledAreasRaw)
            )
        }

        var body: some View {
            List {
                Section {
                    ForEach(sections) { ref in
                        row(for: ref)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Sections")
                } footer: {
                    footerText
                }

                Section {
                    Button {
                        editorMode = .add
                    } label: {
                        Label("Add Section", systemImage: "plus")
                    }
                    .disabled(customSections.count >= CustomHomeSections.maximumCount)
                } header: {
                    Text("Custom Sections")
                } footer: {
                    Text("Build your own row from a public list, like a site's most-popular chart. Lume matches the list against your playlist and shows the titles you have.")
                }

                if let categoryType {
                    Section {
                        NavigationLink {
                            ContentManagementView(fixedType: categoryType)
                        } label: {
                            Label("Categories", systemImage: "square.grid.2x2")
                        }
                    } footer: {
                        Text("Hide and reorder the categories your provider supplies, and choose what appears in the browse sidebar.")
                    }
                }
            }
            // Seeded here as well as on the page itself, so the starting hero is
            // in the list the first time someone opens this screen — even if
            // they come here before visiting the page.
            .onAppear(perform: seedDefaultHeroIfNeeded)
            .platformNavigationTitle(surface.title)
            #if os(iOS)
                // Keep the list permanently in edit mode so the rows are always
                // draggable — no Edit button to enter reorder mode first (matches
                // the Player Engines list). Toggles stay interactive in edit mode.
                .environment(\.editMode, .constant(.active))
            #endif
                .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .sheet(item: $editorMode) { mode in
                    CustomHomeSectionEditor(mode: mode, surface: surface, onSave: save, onDelete: delete)
                }
        }

        /// The Movies and Series pages only ever show one medium, so say so —
        /// that's what makes a movie list added there resolve to nothing.
        @ViewBuilder
        private var footerText: some View {
            switch surface {
            case .home:
                Text("Turn sections on or off and reorder them. Each appears on Home only when it has something to show. \"For You\" is built on-device from your library and what you watch.")
            case .movies:
                Text("Turn sections on or off and reorder them. Each appears only when it has something to show, and only ever shows movies.")
            case .series:
                Text("Turn sections on or off and reorder them. Each appears only when it has something to show, and only ever shows series.")
            }
        }

        // MARK: - Rows

        @ViewBuilder
        private func row(for ref: HomeSectionRef) -> some View {
            switch ref {
            case let .builtin(section):
                HStack {
                    Toggle(isOn: enabledBinding(for: section)) {
                        rowLabel(for: section)
                    }
                    promoteButton(for: ref, name: section.displayName)
                }
            case let .custom(id):
                if let section = customSections.first(where: { $0.id == id }) {
                    customRow(section)
                }
            }
        }

        /// A custom row: the same on/off toggle as a built-in one, plus a pencil
        /// that opens the editor (which also carries the remove action). The
        /// pencil is a borderless button so it stays its own tap target inside
        /// the row, and the whole row also gets a context-menu shortcut.
        private func customRow(_ section: CustomHomeSection) -> some View {
            HStack {
                Toggle(isOn: enabledBinding(for: .custom(section.id))) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: section.title)
                            Text(verbatim: section.provider?.displayName ?? section.sourceURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }

                promoteButton(for: .custom(section.id), name: section.title)

                Button {
                    editorMode = .edit(section)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(section.title)")
            }
            .contextMenu {
                Button("Edit", systemImage: "pencil") { editorMode = .edit(section) }
                Button("Remove", systemImage: "trash", role: .destructive) { delete(id: section.id) }
            }
        }

        /// Creates this surface's starting hero if it has none, as an ordinary
        /// section at the top of the list. Runs once: deleting it leaves it
        /// deleted. Mirrors the pages, which seed it too.
        private func seedDefaultHeroIfNeeded() {
            switch CustomHomeSections.seedingDefaultHero(
                surface: surface,
                sections: customSections,
                heroRaw: heroSectionRaw,
                orderRaw: sectionOrderRaw,
                seeded: heroSeeded
            ) {
            case let .seed(sections, heroToken, orderRaw):
                customSectionsRaw = CustomHomeSections.encode(sections)
                sectionOrderRaw = orderRaw
                heroSectionRaw = heroToken
                heroSeeded = true
            case .alreadyHasHero:
                heroSeeded = true
            case .nothingToDo:
                break
            }
        }

        private func isHero(_ ref: HomeSectionRef) -> Bool {
            HomeLayoutSettings.heroRef(heroSectionRaw) == ref
        }

        /// Promote a row to the hero, or demote it back. Only one row can be the
        /// hero, so promoting replaces whatever held it.
        private func togglePromoted(_ ref: HomeSectionRef) {
            heroSectionRaw = isHero(ref) ? "" : ref.token
        }

        /// The star that promotes a row. Only rows the feed resolves from a list
        /// can be the hero — see `HomeSection.isPromotable`.
        @ViewBuilder
        private func promoteButton(for ref: HomeSectionRef, name: String) -> some View {
            if ref.isPromotable {
                Button {
                    togglePromoted(ref)
                } label: {
                    Image(systemName: isHero(ref) ? "star.fill" : "star")
                        .foregroundStyle(isHero(ref) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isHero(ref) ? "Stop showing \(name) as the hero" : "Show \(name) as the hero")
            }
        }

        /// Rows badged with a crown for free users — Sideload/owned builds are
        /// always premium, so the crown never shows there.
        private static let premiumSections: Set<HomeSection> = [.forYou, .sports]

        @ViewBuilder
        private func rowLabel(for section: HomeSection) -> some View {
            if Self.premiumSections.contains(section), !premium.isPremium {
                Label {
                    HStack(spacing: 6) {
                        Text(section.title)
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                }
            } else {
                Label(section.title, systemImage: section.systemImage)
            }
        }

        // MARK: - Bindings

        /// On/off binding for a built-in section. "For You" maps to the
        /// recommendations flag and is gated behind Lume Pro — a free user turning
        /// it on gets the paywall instead. "Sports" is gated the same way, but
        /// stays in the ordinary disabled set — it has no flag of its own.
        /// Every other section is tracked by `HomeLayoutSettings`' disabled set
        /// (absent ⇒ enabled).
        private func enabledBinding(for section: HomeSection) -> Binding<Bool> {
            guard section == .forYou else {
                guard section == .sports else { return enabledBinding(for: .builtin(section)) }
                return Binding(
                    get: { HomeLayoutSettings.isEnabled(.builtin(section), disabledRaw: disabledSectionsRaw) },
                    set: { isOn in
                        if isOn, !premium.isPremium {
                            paywallHighlight = .sportsHub
                            showPaywall = true
                            return
                        }
                        disabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                            isOn, for: .builtin(section), disabledRaw: disabledSectionsRaw
                        )
                    }
                )
            }
            return Binding(
                get: { recommendationsEnabled },
                set: { isOn in
                    if isOn, !premium.isPremium {
                        // Don't enable; surface the paywall. The toggle snaps
                        // back to off because the getter still returns false.
                        paywallHighlight = .recommendations
                        showPaywall = true
                        return
                    }
                    recommendationsEnabled = isOn
                }
            )
        }

        /// On/off binding for any row tracked by the hidden set — every built-in
        /// section but "For You", and every custom one.
        private func enabledBinding(for ref: HomeSectionRef) -> Binding<Bool> {
            Binding(
                get: { HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw) },
                set: { isOn in
                    disabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                        isOn, for: ref, disabledRaw: disabledSectionsRaw
                    )
                }
            )
        }

        // MARK: - Mutations

        private func move(from offsets: IndexSet, to destination: Int) {
            var list = sections
            list.move(fromOffsets: offsets, toOffset: destination)
            sectionOrderRaw = HomeLayoutSettings.encode(
                HomeLayoutSettings.normalized(list, custom: customSections, surface: surface)
            )
        }

        private func save(_ section: CustomHomeSection) {
            customSectionsRaw = CustomHomeSections.encode(
                CustomHomeSections.upsert(section, into: customSections)
            )
        }

        /// Drops the section and its entry in the stored order, so a later
        /// section added with a fresh id can't inherit its slot.
        private func delete(id: UUID) {
            if isHero(.custom(id)) { heroSectionRaw = "" }
            let remaining = CustomHomeSections.remove(id: id, from: customSections)
            customSectionsRaw = CustomHomeSections.encode(remaining)
            sectionOrderRaw = HomeLayoutSettings.encode(
                HomeLayoutSettings.normalized(
                    sections.filter { $0 != .custom(id) }, custom: remaining, surface: surface
                )
            )
            disabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                true, for: .custom(id), disabledRaw: disabledSectionsRaw
            )
        }
    }

    #Preview {
        NavigationStack {
            SectionLayoutSettingsView(surface: .home)
        }
    }

#endif
