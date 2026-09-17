#if !os(tvOS)

    import SwiftUI

    /// Home screen layout settings (iOS / macOS): switch each Home row on or off
    /// and drag to reorder them. Each row still only appears on Home when it has
    /// something to show. Custom rows built from a list URL are added, edited and
    /// removed here too, and sit in the same order as the built-in ones. See
    /// `HomeLayoutSettings` and `CustomHomeSection`.
    struct HomeLayoutSettingsView: View {
        /// "For You" is the opt-in recommendations row; its toggle writes the same
        /// flag that gates the recommendation recompute on Home.
        @AppStorage(RecommendationSettings.enabledKey) private var recommendationsEnabled = RecommendationSettings.enabledDefault
        @AppStorage(HomeLayoutSettings.sectionOrderKey) private var sectionOrderRaw = ""
        @AppStorage(HomeLayoutSettings.disabledSectionsKey) private var disabledSectionsRaw = ""
        @AppStorage(CustomHomeSections.storageKey) private var customSectionsRaw = ""
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
@State private var paywallHighlight: PremiumFeature = .recommendations
        @State private var editorMode: CustomHomeSectionEditor.Mode?

        private var customSections: [CustomHomeSection] {
            CustomHomeSections.decode(customSectionsRaw)
        }

        private var sections: [HomeSectionRef] {
            HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw, custom: customSections)
        }

        /// Home rows gated behind Lume Pro — badged with a crown and paywalled
        /// when a free user turns one on.
        private static let premiumSections: Set<HomeSection> = [.forYou, .sports]

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
                    Text("Turn sections on or off and reorder them. Each appears on Home only when it has something to show. \"For You\" is built on-device from your library and what you watch.")
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
            }
            .platformNavigationTitle("Home")
            #if os(iOS)
                // Keep the list permanently in edit mode so the rows are always
                // draggable — no Edit button to enter reorder mode first (matches
                // the Player Engines list). Toggles stay interactive in edit mode.
                .environment(\.editMode, .constant(.active))
            #endif
.paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .sheet(item: $editorMode) { mode in
                    CustomHomeSectionEditor(mode: mode, onSave: save, onDelete: delete)
                }
        }

        // MARK: - Rows

        @ViewBuilder
        private func row(for ref: HomeSectionRef) -> some View {
            switch ref {
            case let .builtin(section):
                Toggle(isOn: enabledBinding(for: section)) {
                    rowLabel(for: section)
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

        @ViewBuilder
        private func rowLabel(for section: HomeSection) -> some View {
            // "For You" and "Sports" are Lume Pro features: badge them with a crown
            // for free users (Sideload/owned builds are always premium, so the crown
            // never shows).
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
        /// it on gets the paywall instead. Every other section is tracked by
        /// `HomeLayoutSettings`' disabled set (absent ⇒ enabled).
        private func enabledBinding(for section: HomeSection) -> Binding<Bool> {
if section == .forYou {
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
            return Binding(
                get: { HomeLayoutSettings.isEnabled(.builtin(section), disabledRaw: disabledSectionsRaw) },
                set: { isOn in
                    // "Sports" is a Lume Pro feature: a free user turning it on gets
                    // the paywall instead, and the toggle snaps back off because the
                    // disabled set is left unchanged.
                    if isOn, section == .sports, !premium.isPremium {
                        paywallHighlight = .sportsHub
                        showPaywall = true
                        return
                    }
                    var disabled = HomeLayoutSettings.decodeDisabled(disabledSectionsRaw)
                    if isOn { disabled.remove(section) } else { disabled.insert(section) }
                    disabledSectionsRaw = HomeLayoutSettings.encodeDisabled(disabled)
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
                HomeLayoutSettings.normalized(list, custom: customSections)
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
            let remaining = CustomHomeSections.remove(id: id, from: customSections)
            customSectionsRaw = CustomHomeSections.encode(remaining)
            sectionOrderRaw = HomeLayoutSettings.encode(
                HomeLayoutSettings.normalized(sections.filter { $0 != .custom(id) }, custom: remaining)
            )
            disabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                true, for: .custom(id), disabledRaw: disabledSectionsRaw
            )
        }
    }

    #Preview {
        NavigationStack {
            HomeLayoutSettingsView()
        }
    }

#endif
