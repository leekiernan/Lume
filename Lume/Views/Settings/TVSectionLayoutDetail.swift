//
//  TVSectionLayoutDetail.swift
//  Lume
//
//  The tvOS layout pane for one section surface: each row can be switched on or
//  off and reordered with up / down controls, and custom rows built from a list
//  URL can be added, edited and removed. Mirrors the iOS/macOS
//  `SectionLayoutSettingsView`; the surface picker above it lives in
//  `SettingsView+TVHome`.
//
//  Its own view (rather than an extension on `SettingsView`) because the three
//  surfaces' stored keys differ, and @AppStorage keys are fixed at init.
//

import SwiftUI

#if os(tvOS)

    /// Which custom row the inline form is working on. A sheet would cover the
    /// whole Settings split view on tvOS, so the form grows in place instead —
    /// the same shape as the EPG pane's "Add Custom Source".
    enum TVCustomSectionEditorMode: Identifiable, Hashable {
        case add
        case edit(UUID)

        var id: String {
            switch self {
            case .add: "add"
            case let .edit(id): id.uuidString
            }
        }

        var editingID: UUID? {
            if case let .edit(id) = self { return id }
            return nil
        }
    }

    struct TVSectionLayoutDetail: View {
        private enum FocusTarget: Hashable {
            case addSection
        }

        /// A section as a row of the shared reorderable list.
        private struct Row: ReorderableRowItem {
            let ref: HomeSectionRef
            var id: String {
                ref.token
            }
        }

        let surface: SectionSurface
        /// The settings pane's scroll view, so a lifted row stays in view.
        let proxy: ScrollViewProxy

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
        @State private var editor: TVCustomSectionEditorMode?
        @State private var editorTitle = ""
        @State private var editorURL = ""
        @State private var editorError: String?
        @State private var editorChecking = false
        @State private var isReordering = false
        @FocusState private var focusedControl: FocusTarget?

        init(surface: SectionSurface, proxy: ScrollViewProxy) {
            self.surface = surface
            self.proxy = proxy
            _sectionOrderRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.sectionOrderKey(surface))
            _disabledSectionsRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.disabledSectionsKey(surface))
            _customSectionsRaw = AppStorage(wrappedValue: "", CustomHomeSections.storageKey(surface))
            _heroSectionRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.heroSectionKey(surface))
            _heroSeeded = AppStorage(wrappedValue: false, HomeLayoutSettings.heroSeededKey(surface))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 36) {
                sectionsSection
                customSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Seeded here as well as on the page itself, so the starting hero is
            // in the list the first time someone opens this pane.
            .onAppear(perform: seedDefaultHeroIfNeeded)
            .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
        }

        // MARK: - Derived state

        private var customSections: [CustomHomeSection] {
            CustomHomeSections.decode(customSectionsRaw)
        }

        /// The user's resolved row order (falls back to the surface's default
        /// order until they reorder). See `HomeLayoutSettings`.
        private var sections: [HomeSectionRef] {
            HomeLayoutSettings.resolve(
                orderRaw: sectionOrderRaw, custom: customSections, surface: surface,
                liveTVEnabled: AppAreaSettings.isEnabled(.liveTV, disabledRaw: disabledAreasRaw)
            )
        }

        /// Whether `ref` is switched on. "For You" maps to the recommendations
        /// flag; every other row is tracked by the disabled set.
        private func isEnabled(_ ref: HomeSectionRef) -> Bool {
            ref == .builtin(.forYou)
                ? recommendationsEnabled
                : HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
        }

        private func toggle(_ ref: HomeSectionRef) {
            if ref == .builtin(.forYou) {
                // "For You" is a Lume Pro feature — gate turning it on behind the
                // paywall (disabling it is always allowed).
                if !recommendationsEnabled, !premium.isPremium {
                    paywallHighlight = .recommendations
                    showPaywall = true
                    return
                }
                recommendationsEnabled.toggle()
                return
            }
            // "Sports" is gated the same way, but stays in the ordinary disabled
            // set — it has no flag of its own.
            if ref == .builtin(.sports), !isEnabled(ref), !premium.isPremium {
                paywallHighlight = .sportsHub
                showPaywall = true
                return
            }
            disabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                !isEnabled(ref), for: ref, disabledRaw: disabledSectionsRaw
            )
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

        // MARK: - Sections list

        private var sectionsSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sections")

                // Select a row to lift it, move, select again to place — the
                // same row as every other reorderable list.
                TVReorderableContentList(
                    items: sections.map(Row.init),
                    title: { name(for: $0.ref) },
                    isHidden: { !isEnabled($0.ref) },
                    onToggleHidden: { toggle($0.ref) },
                    onCommitOrder: { rows in
                        sectionOrderRaw = HomeLayoutSettings.encode(
                            HomeLayoutSettings.normalized(rows.map(\.ref), custom: customSections, surface: surface)
                        )
                    },
                    isReordering: $isReordering,
                    scrollProxy: proxy,
                    icon: { icon(for: $0.ref) },
                    accessory: { AnyView(accessory(for: $0.ref)) },
                    actions: { AnyView(actions(for: $0.ref)) }
                )

                Text(footerText)
                    .tvSettingsFooter()
                    .padding(.top, 6)
            }
        }

        private var footerText: LocalizedStringKey {
            switch surface {
            case .home:
                "Turn sections on or off and reorder them. Each appears on Home only when it has something to show. \"For You\" is built on-device from your library and what you watch."
            case .movies:
                "Turn sections on or off and reorder them. Each appears only when it has something to show, and only ever shows movies."
            case .series:
                "Turn sections on or off and reorder them. Each appears only when it has something to show, and only ever shows series."
            }
        }

        private func custom(_ ref: HomeSectionRef) -> CustomHomeSection? {
            ref.customID.flatMap { id in customSections.first { $0.id == id } }
        }

        private func name(for ref: HomeSectionRef) -> String {
            custom(ref)?.title ?? ref.builtin?.displayName ?? ""
        }

        private func icon(for ref: HomeSectionRef) -> String? {
            custom(ref) != nil ? "list.bullet.rectangle" : ref.builtin?.systemImage
        }

        /// "For You" and "Sports" are lume Pro features; badge them for free
        /// users (Sideload/owned builds are always premium, so this never shows).
        @ViewBuilder
        private func accessory(for ref: HomeSectionRef) -> some View {
            if let section = ref.builtin, section == .forYou || section == .sports, !premium.isPremium {
                PremiumBadge()
            }
        }

        /// Promote (a list row), then edit and remove (a custom row) — before
        /// the list's own hide toggle.
        @ViewBuilder
        private func actions(for ref: HomeSectionRef) -> some View {
            let title = name(for: ref)
            if ref.isPromotable {
                Button {
                    togglePromoted(ref)
                } label: {
                    // Filled while this row *is* the hero, so the state reads
                    // without moving focus onto it.
                    Image(systemName: isHero(ref) ? "star.fill" : "star")
                        .foregroundStyle(isHero(ref) ? AnyShapeStyle(Color.lumeAccent) : AnyShapeStyle(.foreground))
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityAddTraits(isHero(ref) ? .isSelected : [])
                .accessibilityLabel(isHero(ref) ? "Stop showing \(title) as the hero" : "Show \(title) as the hero")
            }
            if let section = custom(ref) {
                Button {
                    beginEditing(section)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityLabel("Edit \(title)")

                Button {
                    remove(id: section.id)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityLabel("Remove \(title)")
            }
        }

        // MARK: - Custom sections

        private var customSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Custom Sections")

                if editor == nil {
                    Button {
                        beginAdding()
                    } label: {
                        Label("Add Section", systemImage: "plus")
                            .labelStyle(TVSettingsIconLabelStyle())
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .focused($focusedControl, equals: .addSection)
                    .disabled(customSections.count >= CustomHomeSections.maximumCount || isReordering)

                    Text("Build your own row from a public list, like a site's most-popular chart. lume matches the list against your playlist and shows the titles you have.")
                        .tvSettingsFooter()
                        .padding(.top, 6)

                    Text("Supported: \(supportedProviders).")
                        .tvSettingsFooter()
                } else {
                    editorForm
                }
            }
        }

        private var editorForm: some View {
            VStack(alignment: .leading, spacing: 18) {
                TVSettingsField(
                    title: "Title",
                    placeholder: "Section title",
                    text: $editorTitle,
                    requestsFocusOnAppear: true
                )
                TVSettingsField(title: "List URL", placeholder: "List URL", text: $editorURL, contentType: .URL)

                if let editorError {
                    Text(verbatim: editorError)
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                VStack(spacing: TVSettingsMetrics.rowSpacing) {
                    Button(editorChecking ? "Checking…" : "Save Section") {
                        saveCustomSection()
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(editorChecking || editorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") { cancelEditor() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                }

                Text("Paste the address of a public list, for example \(exampleListURL).")
                    .tvSettingsFooter()
            }
        }

        private var supportedProviders: String {
            HomeListCatalog.providerNames
        }

        private var exampleListURL: String {
            HomeListCatalog.providers.first?.exampleURL ?? ""
        }

        // MARK: - Editor actions

        private func beginAdding() {
            editorTitle = ""
            editorURL = ""
            editorError = nil
            editor = .add
        }

        private func beginEditing(_ section: CustomHomeSection) {
            editorTitle = section.title
            editorURL = section.sourceURL
            editorError = nil
            editor = .edit(section.id)
        }

        private func closeEditor() {
            editor = nil
            editorChecking = false
            editorError = nil
        }

        private func cancelEditor() {
            closeEditor()
            restoreFocus(to: .addSection)
        }

        /// Focus restoration is deferred until the inline editor has left the
        /// hierarchy and its replacement control has a stable focus geometry.
        private func restoreFocus(to target: FocusTarget) {
            Task {
                await Task.yield()
                focusedControl = target
            }
        }

        /// Verifies the list resolves before storing it — a section that can't be
        /// read would otherwise just never appear, with nothing to say why. A list
        /// carrying none of this page's medium is allowed but called out.
        private func saveCustomSection() {
            let url = editorURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = typed.isEmpty ? (HomeListCatalog.suggestedTitle(for: url) ?? "") : typed
            guard !title.isEmpty else {
                editorError = String(localized: "Give the section a title.")
                return
            }
            let id = editor?.editingID ?? UUID()
            editorChecking = true
            editorError = nil
            Task {
                let entries: [HomeListEntry]
                do {
                    entries = try await HomeListCatalog.entries(for: url)
                } catch {
                    editorChecking = false
                    editorError = (error as? HomeListError)?.errorDescription ?? error.localizedDescription
                    return
                }
                customSectionsRaw = CustomHomeSections.encode(CustomHomeSections.upsert(
                    CustomHomeSection(id: id, title: title, sourceURL: url),
                    into: customSections
                ))
                let matchesSurface = surface.mediaType.map { wanted in
                    entries.contains { $0.mediaType == wanted }
                } ?? true
                closeEditor()
                restoreFocus(to: .addSection)
                if !matchesSurface { editorError = mismatchWarning }
            }
        }

        private var mismatchWarning: String {
            switch surface {
            case .home: ""
            case .movies: String(localized: "Saved. That list has no movies on it, so this row will stay empty on the Movies page.")
            case .series: String(localized: "Saved. That list has no series on it, so this row will stay empty on the Series page.")
            }
        }

        /// Drops the section and its entry in the stored order, so a later
        /// section added with a fresh id can't inherit its slot.
        private func remove(id: UUID) {
            if editor?.editingID == id {
                closeEditor()
                restoreFocus(to: .addSection)
            }
            let remaining = CustomHomeSections.remove(id: id, from: customSections)
            let order = sections.filter { $0 != .custom(id) }
            customSectionsRaw = CustomHomeSections.encode(remaining)
            sectionOrderRaw = HomeLayoutSettings.encode(
                HomeLayoutSettings.normalized(order, custom: remaining, surface: surface)
            )
            disabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                true, for: .custom(id), disabledRaw: disabledSectionsRaw
            )
        }
    }

#endif
