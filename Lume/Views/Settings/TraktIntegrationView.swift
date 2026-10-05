//
//  TraktIntegrationView.swift
//  Lume
//
//  The iOS/macOS Trakt integration screen (the tvOS surface is
//  `TVTraktIntegrationView`, shown in SettingsView's Integrations pane). Drives
//  the OAuth device flow: shows the activation code with a one-tap link to open
//  trakt.tv/activate, polls in the background, and surfaces the connected
//  account with a disconnect action.
//

#if !os(tvOS)

    import SwiftData
    import SwiftUI

    struct TraktIntegrationView: View {
        @State private var trakt = TraktService.shared
        /// Trakt is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            List {
                if trakt.isConnected {
                    connectedSection
                } else if let code = trakt.pendingCode {
                    deviceCodeSection(code)
                } else {
                    connectSection
                }
            }
            .platformNavigationTitle("Trakt")
            .paywall(isPresented: $showPaywall, highlight: .trakt)
            .onDisappear {
                // Stop polling if the user backs out mid-connect.
                if !trakt.isConnected {
                    trakt.cancelConnect()
                }
            }
        }

        // MARK: - Connect

        private var connectSection: some View {
            Section {
                Button {
                    if premium.isPremium {
                        trakt.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    SettingsActionLabel(title: "Connect Trakt Account", systemImage: premium.isPremium ? "link" : "crown")
                }
                .disabled(trakt.isConnecting)
            } header: {
                Text("Trakt")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync the movies and episodes you watch to Trakt, and surface your Trakt watchlist on Home.")
                    if let error = trakt.connectionError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }

        // MARK: - Device code

        private func deviceCodeSection(_ code: TraktDeviceCode) -> some View {
            Section {
                TrackerDeviceCodePanel(provider: .trakt, code: code.userCode, activationURL: TraktClient.activationURL(for: code.userCode)) {
                    trakt.cancelConnect()
                }
            }
        }

        // MARK: - Connected

        private var connectedSection: some View {
            Section {
                TrackerConnectedAccount(username: trakt.username)

                Button {
                    Task { await trakt.importWatched(into: modelContext) }
                } label: {
                    SettingsActionLabel(title: "Import Watched from Trakt", systemImage: "arrow.down.circle", isBusy: trakt.isImporting)
                }
                .disabled(trakt.isImporting)

                if trakt.pendingMutationCount > 0 {
                    Button {
                        trakt.retryPendingMutations()
                    } label: {
                        SettingsActionLabel(title: "Retry Pending Trakt Changes", systemImage: "arrow.clockwise", isBusy: trakt.isSyncingMutations)
                    }
                    .disabled(trakt.isSyncingMutations)
                }

                Button(role: .destructive) {
                    Task { await trakt.disconnect() }
                } label: {
                    SettingsActionLabel(title: "Disconnect", systemImage: "xmark.circle")
                }
            } header: {
                Text("Trakt")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watched movies and episodes sync to your Trakt history. Import marks titles you've already watched on Trakt as watched here.")
                    if let summary = trakt.lastImport {
                        importStatus(summary)
                    }
                    if trakt.pendingMutationCount > 0 {
                        if let error = trakt.mutationSyncError {
                            Text(error)
                                .foregroundStyle(.red)
                        } else {
                            Text("\(trakt.pendingMutationCount) Trakt changes waiting to sync.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        private func importStatus(_ summary: TraktImportSummary) -> some View {
            TrackerImportStatus(
                provider: .trakt, movies: summary.moviesMarked, episodes: summary.episodesMarked,
                queuedShows: summary.showsQueued, inProgress: summary.inProgress, failed: summary.failed
            )
        }
    }

#endif
