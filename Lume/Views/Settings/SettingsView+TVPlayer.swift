//
//  SettingsView+TVPlayer.swift
//  Lume
//
//  The tvOS Player settings pane: the premium-gated playback toggles, the engine
//  priority list with reordering, the external-player cycle, and per-engine option
//  drill-ins. Split out of SettingsView to keep that file within the project's
//  line-count cap.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        /// The primary (most-preferred) engine — its description is shown under
        /// the priority list.
        private var primaryEngine: PlayerEngineKind {
            enginePriority.first ?? .defaultValue
        }

        /// Persists a new priority order, keeping the legacy single-engine key in
        /// sync with the primary so other readers (and a downgrade) still resolve it.
        private func setEnginePriority(_ list: [PlayerEngineKind]) {
            let normalized = PlayerEnginePriority.normalized(list)
            enginePriorityRaw = PlayerEnginePriority.encode(normalized)
            engineRaw = normalized.first?.rawValue ?? PlayerEngineKind.defaultValue.rawValue
        }

        func tvPlayerDetail(proxy: ScrollViewProxy) -> some View {
            VStack(alignment: .leading, spacing: 28) {
                tvPlaybackSection

                // Second in the pane, right under Playback: this is a
                // viewer-facing playback preference (and the one that otherwise
                // costs a menu trip on every zap), where everything below —
                // engine order, hand-off, per-engine options — is technical
                // setup touched once.
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Languages")

                    VStack(spacing: 2) {
                        tvPreferredLanguageRow()
                    }
                }

                // Viewer-facing too, so it belongs up here with Languages
                // rather than among the engine sections — and it is
                // engine-independent: all three hosts route their up/down
                // presses through LiveChannelNavigator.
                tvLiveTVSection

                // Its own section rather than a row under Live TV: it governs
                // every direction the player reads, VOD scrubbing included,
                // and it is about the remote rather than about channels.
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Siri Remote")

                    TVOptionToggleRow(title: "Swipe Gestures", isOn: $tvRemoteSwipes)

                    // swiftlint:disable:next line_length
                    Text("Swipes across the remote's touch surface control the player: up and down change channels, left opens the channel browser and right returns to the last channel. Turn this off to leave those to a click on the remote's direction buttons, so a brush across the surface changes nothing.")
                        .tvSettingsFooter()
                        .padding(.top, 6)
                }

                tvStreamInfoSection

                tvEnginePrioritySection(proxy: proxy)

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("External Player")

                    TVOptionCycleRow(
                        title: "External Player",
                        valueLabel: ExternalPlayer(rawValue: externalPlayerRaw)?.displayName
                            ?? String(localized: "Off")
                    ) {
                        // Off, then each player in turn, then back to Off.
                        externalPlayerRaw = PlayerOptionCycle.next(externalPlayerRaw, in: ExternalPlayer.self, offValue: "")
                    }

                    // Only meaningful once a player is selected — some players
                    // (Infuse, for one) handle VOD but not live streams.
                    if ExternalPlayer(rawValue: externalPlayerRaw) != nil {
                        TVOptionCycleRow(
                            title: "Use For",
                            valueLabel: ExternalPlayerScope(rawValue: externalPlayerScopeRaw)?.displayName
                                ?? ExternalPlayerScope.default.displayName
                        ) {
                            externalPlayerScopeRaw = PlayerOptionCycle.next(
                                externalPlayerScopeRaw, in: ExternalPlayerScope.self, fallback: .default
                            )
                        }
                    }

                    // swiftlint:disable:next line_length
                    Text("Streams open in the selected app instead of lume's player. Downloads always play in lume, and the built-in player is used when the app is not installed or the stream is outside the selected content.")
                        .tvSettingsFooter()
                        .padding(.top, 6)
                }

                // Each engine's options live behind a dedicated row, so they're
                // all reachable regardless of the priority order. AVPlayer has no
                // configurable options, so it isn't listed.
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Engine Options")
                    VStack(spacing: 2) {
                        tvEngineOptionsRow(.vlcKit)
                        tvEngineOptionsRow(.ksPlayer)
                    }
                }
            }
        }

        /// A drill-in row that replaces the player detail with the given engine's
        /// options in place. Returning focus to the sidebar (Menu) restores it.
        private func tvEngineOptionsRow(_ engine: PlayerEngineKind) -> some View {
            Button {
                selectedEngineOptions = engine
            } label: {
                HStack(spacing: 16) {
                    Text("\(engine.displayName) Options")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        private var tvPlaybackSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Playback")
                TVOptionToggleRow(title: "Autoplay Next Episode", isOn: $autoPlayNext)
                    .disabled(!premium.isPremium)
                TVOptionToggleRow(title: "Show Next Episode Button", isOn: $showNextEpisodeButton)
                    .disabled(!premium.isPremium)
                TVOptionToggleRow(title: "Show Skip Intro Button", isOn: $showSkipIntroButton)
                    .disabled(!premium.isPremium)
                if !premium.isPremium {
                    Button {
                        presentPaywall(.playbackControls)
                    } label: {
                        Label("Unlock with Premium", systemImage: "crown")
                            .labelStyle(TVSettingsIconLabelStyle())
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                }
            }
        }

        private var tvLiveTVSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Live TV")

                TVOptionCycleRow(
                    title: "Up & Down",
                    valueLabel: LiveSurfMode.resolve(liveSurfModeRaw).displayName
                ) {
                    liveSurfModeRaw = PlayerOptionCycle.next(
                        liveSurfModeRaw, in: LiveSurfMode.self, fallback: .default
                    )
                }

                Text("Up and down move to the next and previous channel, like a TV remote. List Order moves the way the channel list reads on screen instead — up goes to the row above.")
                    .tvSettingsFooter()
                    .padding(.top, 6)
            }
        }

        /// Select an engine to lift it, move, select again to place.
        private func tvEnginePrioritySection(proxy: ScrollViewProxy) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Engine Priority")

                TVReorderableContentList(
                    items: enginePriority.map(TVEngineRow.init),
                    title: { $0.kind.displayName },
                    isHidden: { _ in false },
                    onToggleHidden: nil,
                    onCommitOrder: { setEnginePriority($0.map(\.kind)) },
                    isReordering: $isReorderingPlayerList,
                    scrollProxy: proxy,
                    accessory: { row in
                        AnyView(Group {
                            if row.kind == enginePriority.first {
                                Text("Primary")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        })
                    }
                )

                Text(primaryEngine.subtitle)
                    .tvSettingsFooter()
                    .padding(.top, 6)
            }
        }

        // MARK: - Preferred languages

        /// The stored list, most-preferred first. Empty is Automatic and uses
        /// the device's preferred languages.
        private var preferredLanguageCodes: [String] {
            PreferredLanguageList.decode(preferredAudioLanguagesRaw)
        }

        /// Deferred: the reorder and remove buttons run inside the focus
        /// engine's animated context, and rewriting the list rebuilds the
        /// `ForEach` under it. Mutating on the next turn lets the engine finish
        /// the move it is already animating and keeps focus on the row.
        private func setPreferredLanguageCodes(_ codes: [String]) {
            let encoded = PreferredLanguageList.encode(codes)
            Task { preferredAudioLanguagesRaw = encoded }
        }

        private func removePreferredLanguage(_ code: String) {
            setPreferredLanguageCodes(preferredLanguageCodes.filter { $0 != code })
        }

        /// A drill-in row that replaces the player detail with the language
        /// list in place, mirroring `tvEngineOptionsRow`.
        private func tvPreferredLanguageRow() -> some View {
            Button {
                preferredLanguagePane = .list
            } label: {
                HStack(spacing: 16) {
                    Text("Audio Languages")
                    Spacer(minLength: 16)
                    tvPreferredLanguageValue
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        /// The row's trailing summary. `.opacity` rather than `.secondary`: the
        /// focused row's label turns black, which a secondary style washes out.
        @ViewBuilder
        private var tvPreferredLanguageValue: some View {
            let codes = preferredLanguageCodes
            Group {
                if codes.isEmpty {
                    Text("Automatic")
                } else {
                    Text(verbatim: codes.map { TrackLanguageMatcher.displayName(for: $0) }.joined(separator: ", "))
                }
            }
            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(0.6)
        }

        /// The drilled-in pane for the language list: the ordered list itself,
        /// or the add picker one level deeper.
        @ViewBuilder
        func tvPreferredLanguageDetail(_ pane: PreferredLanguagePane, proxy: ScrollViewProxy) -> some View {
            switch pane {
            case .list: tvPreferredLanguageOrderDetail(proxy: proxy)
            case .add: tvAddPreferredLanguageDetail()
            }
        }

        private func tvPreferredLanguageOrderDetail(proxy: ScrollViewProxy) -> some View {
            let codes = preferredLanguageCodes
            return VStack(alignment: .leading, spacing: 28) {
                Text("Audio Languages")
                    .font(.system(size: TVSettingsMetrics.paneTitleFontSize, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Preferred Order")

                    if codes.isEmpty {
                        Text("No Preferred Languages")
                            .tvSettingsSecondaryText()
                    } else {
                        TVReorderableContentList(
                            items: codes.map(TVLanguageRow.init),
                            title: { TrackLanguageMatcher.displayName(for: $0.code) },
                            isHidden: { _ in false },
                            onToggleHidden: nil,
                            onCommitOrder: { setPreferredLanguageCodes($0.map(\.code)) },
                            isReordering: $isReorderingPlayerList,
                            scrollProxy: proxy,
                            actions: { row in
                                AnyView(Button {
                                    removePreferredLanguage(row.code)
                                } label: {
                                    Image(systemName: "minus")
                                }
                                .buttonStyle(TVContentIconButtonStyle())
                                .accessibilityLabel("Remove \(TrackLanguageMatcher.displayName(for: row.code))"))
                            }
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        preferredLanguagePane = .add
                    } label: {
                        HStack(spacing: 16) {
                            Text("Add Language")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())

                    Text(tvPreferredLanguageFooter)
                        .tvSettingsFooter()
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var tvPreferredLanguageFooter: LocalizedStringKey {
            // swiftlint:disable:next line_length
            "lume selects the first of these languages the stream offers as an audio track, most preferred at the top. When the audio that plays is in none of them and the stream carries a forced subtitle track, that track is turned on. Applied the next time playback starts."
        }

        /// The add picker: the device's own languages first, then the curated
        /// shortlist. Deliberately not the full ISO list — several hundred
        /// focusable rows is a scroll and VoiceOver hazard on tvOS, and this
        /// pane has no search field.
        private func tvAddPreferredLanguageDetail() -> some View {
            let addable = PreferredLanguageCatalog.addable(excluding: preferredLanguageCodes)

            return VStack(alignment: .leading, spacing: 28) {
                Text("Add Language")
                    .font(.system(size: TVSettingsMetrics.paneTitleFontSize, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                if !addable.suggested.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        TVSettingsSectionLabel("Suggested")
                        VStack(spacing: 2) {
                            ForEach(addable.suggested) { tvAddPreferredLanguageRow($0) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Common Languages")
                    if addable.common.isEmpty {
                        Text("No Languages Found")
                            .tvSettingsSecondaryText()
                    } else {
                        VStack(spacing: 2) {
                            ForEach(addable.common) { tvAddPreferredLanguageRow($0) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func tvAddPreferredLanguageRow(_ language: PreferredLanguage) -> some View {
            Button {
                setPreferredLanguageCodes(preferredLanguageCodes + [language.code])
                preferredLanguagePane = .list
            } label: {
                HStack(spacing: 16) {
                    Text(verbatim: language.name)
                    Spacer(minLength: 16)
                    Text(verbatim: language.code.uppercased())
                        .font(.system(size: TVSettingsMetrics.secondaryFontSize).monospaced())
                        .opacity(0.6)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }

    /// An engine as a row of the shared reorderable list.
    private struct TVEngineRow: ReorderableRowItem {
        let kind: PlayerEngineKind
        var id: String {
            kind.rawValue
        }
    }

    /// A preferred audio language as a row of the shared reorderable list.
    private struct TVLanguageRow: ReorderableRowItem {
        let code: String
        var id: String {
            code
        }
    }
#endif
