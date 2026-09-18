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
            case section(HomeSectionRef)
        }

        let surface: SectionSurface

        @AppStorage(RecommendationSettings.enabledKey) private var recommendationsEnabled = RecommendationSettings.enabledDefault
        @AppStorage private var sectionOrderRaw: String
        @AppStorage private var disabledSectionsRaw: String
        @AppStorage private var customSectionsRaw: String
        @AppStorage private var heroSectionRaw: String

        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @State private var editor: TVCustomSectionEditorMode?
        @State private var editorTitle = ""
        @State private var editorURL = ""
        @State private var editorError: String?
        @State private var editorChecking = false
        @FocusState private var focusedControl: FocusTarget?

        init(surface: SectionSurface) {
            self.surface = surface
            _sectionOrderRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.sectionOrderKey(surface))
            _disabledSectionsRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.disabledSectionsKey(surface))
            _customSectionsRaw = AppStorage(wrappedValue: "", CustomHomeSections.storageKey(surface))
            _heroSectionRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.heroSectionKey(surface))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 36) {
                sectionsSection
                customSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paywall(isPresented: $showPaywall, highlight: .recommendations)
        }

        // MARK: - Derived state

        private var customSections: [CustomHomeSection] {
            CustomHomeSections.decode(customSectionsRaw)
        }

        /// The user's resolved row order (falls back to the surface's default
        /// order until they reorder). See `HomeLayoutSettings`.
        private var sections: [HomeSectionRef] {
            HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw, custom: customSections, surface: surface)
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
                    showPaywall = true
                    return
                }
                recommendationsEnabled.toggle()
                return
            }
            disabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                !isEnabled(ref), for: ref, disabledRaw: disabledSectionsRaw
            )
        }

        /// Whether this section is the surface's hero.
        private func isPromoted(_ id: UUID) -> Bool {
            UUID(uuidString: heroSectionRaw) == id
        }

        /// Promote a section to the hero, or demote it back to a row. Only one
        /// can be the hero, so promoting replaces whatever held it.
        private func togglePromoted(_ id: UUID) {
            heroSectionRaw = isPromoted(id) ? "" : id.uuidString
        }

        /// Move the section at `index` one slot up or down, persisting the new
        /// order. Mirrors `moveEngine` in the player pane.
        private func move(at index: Int, by offset: Int) {
            var list = sections
            guard list.move(at: index, by: offset) else { return }
            sectionOrderRaw = HomeLayoutSettings.encode(
                HomeLayoutSettings.normalized(list, custom: customSections, surface: surface)
            )
        }

        // MARK: - Sections list

        private var sectionsSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sections")

                VStack(spacing: 2) {
                    ForEach(Array(sections.enumerated()), id: \.element) { index, ref in
                        sectionRow(ref: ref, index: index)
                    }
                }

                Text(footerText)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
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

        /// One row of the tvOS section list: an on/off control and the section
        /// name, then the shared trailing cluster of icon controls. A custom row
        /// fills in the edit and remove slots there, so its up / down pair still
        /// lines up with the built-in rows'. Mirrors `tvEnginePriorityRow`.
        private func sectionRow(ref: HomeSectionRef, index: Int) -> some View {
            let enabled = isEnabled(ref)
            let custom = ref.customID.flatMap { id in customSections.first { $0.id == id } }
            let name = custom?.title ?? ref.builtin?.displayName ?? ""
            return TVSettingsReorderRow(
                name: name,
                index: index,
                count: sections.count,
                onMove: { move(at: index, by: $0) },
                onEdit: custom.map { section in { beginEditing(section) } },
                onRemove: custom.map { section in { remove(id: section.id) } },
                onPromote: custom.map { section in { togglePromoted(section.id) } },
                isPromoted: custom.map { isPromoted($0.id) } ?? false,
                leading: {
                    Button {
                        toggle(ref)
                    } label: {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(TVContentIconButtonStyle())
                    .focused($focusedControl, equals: .section(ref))
                    .accessibilityLabel(Text(verbatim: name))
                    .accessibilityValue(enabled ? Text("On") : Text("Off"))

                    if let custom {
                        Label {
                            Text(verbatim: custom.title)
                        } icon: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .font(.system(size: TVSettingsMetrics.rowFontSize))
                        .foregroundStyle(enabled ? .primary : .secondary)
                    } else if let section = ref.builtin {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.system(size: TVSettingsMetrics.rowFontSize))
                            .foregroundStyle(enabled ? .primary : .secondary)

                        // "For You" is a Lume Pro feature; badge it for free users
                        // (Sideload/owned builds are always premium, so this never shows).
                        if section == .forYou, !premium.isPremium {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            )
        }

        // MARK: - Custom sections

        private var customSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Custom Sections")

                if editor == nil {
                    Button {
                        beginAdding()
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                            Text("Add Section")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .focused($focusedControl, equals: .addSection)
                    .disabled(customSections.count >= CustomHomeSections.maximumCount)

                    Text("Build your own row from a public list, like a site's most-popular chart. Lume matches the list against your playlist and shows the titles you have.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)

                    Text("Supported: \(supportedProviders).")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
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

                VStack(spacing: 2) {
                    Button(editorChecking ? "Checking…" : "Save Section") {
                        saveCustomSection()
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(editorChecking || editorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") { cancelEditor() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                }

                Text("Paste the address of a public list, for example \(exampleListURL).")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }
        }

        private var supportedProviders: String {
            HomeListCatalog.providers.map(\.displayName).formatted(.list(type: .and))
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
            let returnTarget = editor?.editingID.map { FocusTarget.section(.custom($0)) } ?? .addSection
            closeEditor()
            restoreFocus(to: returnTarget)
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
                restoreFocus(to: .section(.custom(id)))
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
            if isPromoted(id) { heroSectionRaw = "" }
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
