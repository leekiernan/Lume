//
//  TVQuickSwitchOverlay.swift
//  Lume
//
//  The tvOS quick-switch modal: playlists on the left, profiles on the right,
//  a checkmark on the active row of each. Switching only — adding, editing and
//  deleting stay in Settings, which remains the management surface.
//
//  Presented as a plain overlay, never a `fullScreenCover`: a tvOS cover always
//  self-dismisses on Menu, and neither `onExitCommand` nor
//  `interactiveDismissDisabled` stops it.
//

#if os(tvOS)

    import SwiftUI

    struct TVQuickSwitchOverlay: View {
        /// Owns the presentation flag this modal clears to dismiss itself. Handed
        /// in rather than read from the environment: this modal is layered onto
        /// the tab content by `MainTabView`, not nested inside it.
        let router: DeepLinkRouter
        /// Handed in for the same reason, and because `MainTabView` already holds
        /// this fetch — a `@Query` here would register a second store observer
        /// for the identical result.
        let playlists: [Playlist]

        /// The roster comes from `ProfileManager` — `UserProfile` lives in the
        /// CloudKit-mirrored store, a separate container the browse `@Query`s
        /// don't bind to.
        @Environment(ProfileManager.self) private var profileManager: ProfileManager?
        @Environment(ParentalControls.self) private var parental: ParentalControls?
        @Environment(PlaylistSwitchModel.self) private var playlistSwitch: PlaylistSwitchModel?
        @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

        /// A profile awaiting PIN entry before the switch goes through.
        @State private var pendingSwitch: UserProfile?

        @FocusState private var focus: FocusTarget?
        /// Where focus first landed this presentation. The resolved target
        /// moves as a playlist switch finishes, the profile manager becomes
        /// ready or the roster updates from iCloud; following it would pull
        /// focus away from wherever the viewer has since moved.
        @State private var landingTarget: FocusTarget?

        private typealias FocusTarget = QuickSwitchFocusTarget

        var body: some View {
            let playlistRows = QuickSwitchResolver.playlistRows(playlists, storedID: selectedPlaylistID)
            let profileRows = resolvedProfileRows
            let resolvedTarget = QuickSwitchResolver.initialFocus(
                playlists: playlistRows, profiles: profileRows,
                canSwitchPlaylist: playlistSwitch?.isSwitching != true, canSwitchProfile: !profileColumnDisabled
            )
            let focusTarget = landingTarget ?? resolvedTarget

            return ZStack {
                Color.black.opacity(0.92)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 28) {
                    Text(
                        "Quick Switch",
                        comment: "Title of the tvOS quick-switch modal, which switches the active playlist or profile"
                    )
                    .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                    .foregroundStyle(.white)

                    HStack(alignment: .top, spacing: 60) {
                        playlistColumn(playlistRows, target: focusTarget)
                        profileColumn(profileRows, target: focusTarget)
                    }

                    Text(
                        "Press Menu to close",
                        comment: "Hint at the bottom of the tvOS quick-switch modal telling the viewer which remote button closes it"
                    )
                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, TVLayoutMetrics.modalHorizontalInset)
                .padding(.vertical, TVLayoutMetrics.modalVerticalInset)
            }
            .defaultFocus($focus, focusTarget, priority: .userInitiated)
            .onChange(of: resolvedTarget, initial: true) { _, target in
                if landingTarget == nil, let target { landingTarget = target }
            }
            .onExitCommand(perform: close)
            .pinPrompt(target: $pendingSwitch) { profile in
                guard let profileManager else { return }
                close()
                Task { await profileManager.switchProfile(to: profile.id) }
            }
        }

        // MARK: - Columns

        private func playlistColumn(_ rows: [QuickSwitchRow<Playlist>], target: FocusTarget?) -> some View {
            column("Playlists", width: TVSettingsMetrics.contentMaxWidth, target: target?.isPlaylist == true ? target : nil) {
                if rows.isEmpty {
                    emptyLabel(
                        Text(
                            "No playlists yet",
                            comment: "Empty state shown in the playlists column of the tvOS quick-switch modal"
                        )
                    )
                } else {
                    ForEach(rows) { row in
                        TVPlaylistSwitchRow(playlist: row.item, isActive: row.isCurrent) {
                            select(playlist: row)
                        }
                        .focused($focus, equals: .playlist(row.id))
                        .id(FocusTarget.playlist(row.id))
                    }
                }
            }
            .disabled(playlistSwitch?.isSwitching == true)
        }

        private func profileColumn(_ rows: [QuickSwitchRow<UserProfile>], target: FocusTarget?) -> some View {
            column("Profiles", width: TVSettingsMetrics.sideColumnWidth, target: target?.isPlaylist == false ? target : nil) {
                if rows.isEmpty {
                    emptyLabel(
                        Text(
                            "No profiles yet",
                            comment: "Empty state shown in the profiles column of the tvOS quick-switch modal"
                        )
                    )
                } else {
                    ForEach(rows) { row in
                        TVProfileSwitchRow(profile: row.item, isActive: row.isCurrent) {
                            select(profile: row)
                        }
                        .focused($focus, equals: .profile(row.id))
                        .id(FocusTarget.profile(row.id))
                    }
                }
            }
            .disabled(profileColumnDisabled)
        }

        /// One column of full-width rows. Its own focus section, so left/right hop
        /// between the two lists rather than walking row by row.
        private func column(
            _ title: LocalizedStringKey,
            width: CGFloat,
            target: FocusTarget?,
            @ViewBuilder rows: @escaping () -> some View
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel(title)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            rows()
                        }
                        .padding(.bottom, 24)
                    }
                    .task(id: target) {
                        await landTVFocus($focus, on: target, scrollingTo: proxy) { router.isQuickSwitchPresented && pendingSwitch == nil }
                    }
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .focusSection()
        }

        private func emptyLabel(_ text: Text) -> some View {
            text
                .tvSettingsSecondaryText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }

        // MARK: - Rows

        private var resolvedProfileRows: [QuickSwitchRow<UserProfile>] {
            guard let profileManager else { return [] }
            return QuickSwitchResolver.profileRows(
                profileManager.profiles,
                activeProfileID: profileManager.activeProfileID
            )
        }

        /// A switch in flight, or a roster that hasn't resolved yet, would leave
        /// the catalog half-projected — the playlist column stays open either way,
        /// including to a child profile.
        private var profileColumnDisabled: Bool {
            guard let profileManager else { return true }
            return profileManager.isSwitching || !profileManager.isReady
        }

        // MARK: - Switching

        /// Dismisses the modal. Always called before a switch is applied, so the
        /// switch progress overlay never stacks on top of this one.
        private func close() {
            router.isQuickSwitchPresented = false
        }

        /// Picking the active row just closes the modal.
        private func select(playlist row: QuickSwitchRow<Playlist>) {
            guard !row.isCurrent else {
                close()
                return
            }
            let id = row.item.id.uuidString
            let name = row.item.name
            close()
            if let playlistSwitch {
                // The viewer asked to be somewhere else now: land in the cached
                // catalog and leave the due sync to the next launch / foreground.
                playlistSwitch.switchTo(id: id, name: name, deferringDueSync: true) { selectedPlaylistID = id }
            } else {
                selectedPlaylistID = id
            }
        }

        private func select(profile row: QuickSwitchRow<UserProfile>) {
            guard let profileManager, !row.isCurrent else {
                close()
                return
            }
            if parental?.requiresPIN(toSwitchTo: row.item) == true {
                pendingSwitch = row.item
                return
            }
            close()
            Task { await profileManager.switchProfile(to: row.item.id) }
        }
    }

#endif
