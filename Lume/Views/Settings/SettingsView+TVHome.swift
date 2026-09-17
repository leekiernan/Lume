//
//  SettingsView+TVHome.swift
//  Lume
//
//  The tvOS Home settings pane: each Home row can be switched on or off and
//  reordered with up / down controls, and custom rows built from a list URL can
//  be added, edited and removed. Mirrors the engine priority pane
//  (SettingsView+TVPlayer) and the iOS HomeLayoutSettingsView.
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

    extension SettingsView {
        /// The user's resolved Home row order (falls back to the declaration
        /// order until they reorder). See `HomeLayoutSettings`.
        private var homeSections: [HomeSectionRef] {
            HomeLayoutSettings.resolve(orderRaw: homeSectionOrderRaw, custom: homeCustomSections)
        }

        private var homeCustomSections: [CustomHomeSection] {
            CustomHomeSections.decode(homeCustomSectionsRaw)
        }

        /// Whether `ref` is switched on. "For You" maps to the recommendations
        /// flag; every other row is tracked by the disabled set.
        private func isHomeSectionEnabled(_ ref: HomeSectionRef) -> Bool {
            ref == .builtin(.forYou)
                ? recommendationsEnabled
                : HomeLayoutSettings.isEnabled(ref, disabledRaw: homeDisabledSectionsRaw)
        }

        private func toggleHomeSection(_ ref: HomeSectionRef) {
            if ref == .builtin(.forYou) {
                // "For You" is a Lume Pro feature — gate turning it on behind the
                // paywall (disabling it is always allowed).
                if !recommendationsEnabled, !premium.isPremium {
                    presentPaywall(.recommendations)
                    return
                }
                recommendationsEnabled.toggle()
                return
            }
// "Sports" is a Lume Pro feature — gate turning it on behind the
            // paywall (disabling it is always allowed).
            if ref == .builtin(.sports), !isHomeSectionEnabled(ref), !premium.isPremium {
                presentPaywall(.sportsHub)
                return
            }
            homeDisabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                !isHomeSectionEnabled(ref), for: ref, disabledRaw: homeDisabledSectionsRaw
            )
        }

        /// Move the section at `index` one slot up or down, persisting the new
        /// order. Mirrors `moveEngine` in the player pane.
        private func moveSection(at index: Int, by offset: Int) {
            var list = homeSections
            guard list.move(at: index, by: offset) else { return }
            homeSectionOrderRaw = HomeLayoutSettings.encode(
                HomeLayoutSettings.normalized(list, custom: homeCustomSections)
            )
        }

        var tvHomeLayoutDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                tvHomeSectionsSection
                tvHomeCustomSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var tvHomeSectionsSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sections")

                VStack(spacing: 2) {
                    ForEach(Array(homeSections.enumerated()), id: \.element) { index, ref in
                        tvHomeSectionRow(ref: ref, index: index)
                    }
                }

                Text("Turn sections on or off and reorder them. Each appears on Home only when it has something to show. \"For You\" is built on-device from your library and what you watch.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }

        /// One row of the tvOS Home section list: an on/off control, the section
        /// name, and up / down controls that reorder the list. A custom row adds
        /// an edit button and the shared remove control. Mirrors
        /// `tvEnginePriorityRow`.
        private func tvHomeSectionRow(ref: HomeSectionRef, index: Int) -> some View {
            let enabled = isHomeSectionEnabled(ref)
            let custom = ref.customID.flatMap { id in homeCustomSections.first { $0.id == id } }
            let name = custom?.title ?? ref.builtin?.displayName ?? ""
            return TVSettingsReorderRow(
                name: name,
                index: index,
                count: homeSections.count,
                onMove: { moveSection(at: index, by: $0) },
                onRemove: custom.map { section in { removeCustomSection(id: section.id) } },
                leading: {
                    Button {
                        toggleHomeSection(ref)
                    } label: {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(TVContentIconButtonStyle())
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

                        Button {
                            beginEditingCustomSection(custom)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(TVContentIconButtonStyle())
                        .accessibilityLabel(Text("Edit \(custom.title)"))
                    } else if let section = ref.builtin {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.system(size: TVSettingsMetrics.rowFontSize))
                            .foregroundStyle(enabled ? .primary : .secondary)

                        // "For You" and "Sports" are Lume Pro features; badge them
                        // for free users (Sideload/owned builds are always
                        // premium, so this never shows).
                        if section == .forYou || section == .sports, !premium.isPremium {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            )
        }

        // MARK: - Custom sections

        private var tvHomeCustomSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Custom Sections")

                if homeSectionEditor == nil {
                    Button {
                        beginAddingCustomSection()
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                            Text("Add Section")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(homeCustomSections.count >= CustomHomeSections.maximumCount)

                    Text("Build your own row from a public list, like a site's most-popular chart. Lume matches the list against your playlist and shows the titles you have.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)

                    Text("Supported: \(supportedListProviders).")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                } else {
                    tvHomeCustomSectionForm
                }
            }
        }

        private var tvHomeCustomSectionForm: some View {
            VStack(alignment: .leading, spacing: 18) {
                TVSettingsField(title: "Title", placeholder: "Section title", text: $homeSectionEditorTitle)
                TVSettingsField(
                    title: "List URL",
                    placeholder: "List URL",
                    text: $homeSectionEditorURL,
                    contentType: .URL
                )

                if let homeSectionEditorError {
                    Text(verbatim: homeSectionEditorError)
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                VStack(spacing: 2) {
                    Button(homeSectionEditorChecking ? "Checking…" : "Save Section") {
                        saveCustomSection()
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(
                        homeSectionEditorChecking
                            || homeSectionEditorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    Button("Cancel") { closeCustomSectionEditor() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                }

                Text("Paste the address of a public list, for example \(exampleListURL).")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }
        }

        private var supportedListProviders: String {
            HomeListCatalog.providers.map(\.displayName).formatted(.list(type: .and))
        }

        private var exampleListURL: String {
            HomeListCatalog.providers.first?.exampleURL ?? ""
        }

        private func beginAddingCustomSection() {
            homeSectionEditorTitle = ""
            homeSectionEditorURL = ""
            homeSectionEditorError = nil
            homeSectionEditor = .add
        }

        private func beginEditingCustomSection(_ section: CustomHomeSection) {
            homeSectionEditorTitle = section.title
            homeSectionEditorURL = section.sourceURL
            homeSectionEditorError = nil
            homeSectionEditor = .edit(section.id)
        }

        private func closeCustomSectionEditor() {
            homeSectionEditor = nil
            homeSectionEditorChecking = false
            homeSectionEditorError = nil
        }

        /// Verifies the list resolves before storing it — a section that can't be
        /// read would otherwise just never appear on Home, with nothing to say why.
        private func saveCustomSection() {
            let url = homeSectionEditorURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = homeSectionEditorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = typed.isEmpty ? (HomeListCatalog.suggestedTitle(for: url) ?? "") : typed
            guard !title.isEmpty else {
                homeSectionEditorError = String(localized: "Give the section a title.")
                return
            }
            let id = homeSectionEditor?.editingID ?? UUID()
            homeSectionEditorChecking = true
            homeSectionEditorError = nil
            Task {
                do {
                    _ = try await HomeListCatalog.entries(for: url)
                } catch {
                    homeSectionEditorChecking = false
                    homeSectionEditorError = (error as? HomeListError)?.errorDescription
                        ?? error.localizedDescription
                    return
                }
                homeCustomSectionsRaw = CustomHomeSections.encode(CustomHomeSections.upsert(
                    CustomHomeSection(id: id, title: title, sourceURL: url),
                    into: homeCustomSections
                ))
                closeCustomSectionEditor()
            }
        }

        /// Drops the section and its entry in the stored order, so a later
        /// section added with a fresh id can't inherit its slot.
        private func removeCustomSection(id: UUID) {
            if homeSectionEditor?.editingID == id { closeCustomSectionEditor() }
            let remaining = CustomHomeSections.remove(id: id, from: homeCustomSections)
            let order = homeSections.filter { $0 != .custom(id) }
            homeCustomSectionsRaw = CustomHomeSections.encode(remaining)
            homeSectionOrderRaw = HomeLayoutSettings.encode(
                HomeLayoutSettings.normalized(order, custom: remaining)
            )
            homeDisabledSectionsRaw = HomeLayoutSettings.settingEnabled(
                true, for: .custom(id), disabledRaw: homeDisabledSectionsRaw
            )
        }
    }

#endif
