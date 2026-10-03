//
//  TVTraktIntegrationView.swift
//  Lume
//
//  The tvOS Integrations pane content for Trakt, shown inside SettingsView's
//  detail column. Drives the OAuth device flow with a scannable QR code (Apple
//  TV can't open a browser), and surfaces the connected account.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVTraktIntegrationView: View {
        @State private var trakt = TraktService.shared
        /// Trakt is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Trakt")

                if trakt.isConnected {
                    connected
                } else if let code = trakt.pendingCode {
                    deviceCode(code)
                } else {
                    connect
                }
            }
            .paywall(isPresented: $showPaywall, highlight: .trakt)
            .onDisappear {
                // Stop polling if the user leaves the pane mid-connect.
                if !trakt.isConnected {
                    trakt.cancelConnect()
                }
            }
        }

        private var connect: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync the movies and episodes you watch to Trakt, and surface your Trakt watchlist on Home.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    if premium.isPremium {
                        trakt.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: premium.isPremium ? "link" : "crown")
                            .font(.system(size: 22, weight: .medium))
                        Text("Connect Trakt Account")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(trakt.isConnecting)

                if let error = trakt.connectionError {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
        }

        private func deviceCode(_ code: TraktDeviceCode) -> some View {
            TrackerDeviceCodePanel(provider: .trakt, code: code.userCode, activationURL: TraktClient.activationURL(for: code.userCode)) {
                trakt.cancelConnect()
            }
        }

        private var connected: some View {
            VStack(alignment: .leading, spacing: 16) {
                TrackerConnectedAccount(username: trakt.username)

                Text("Watched movies and episodes sync to your Trakt history. Import marks titles you've already watched on Trakt as watched here.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    Task { await trakt.importWatched(into: modelContext) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 22, weight: .medium))
                        Text("Import Watched from Trakt")
                        Spacer(minLength: 0)
                        if trakt.isImporting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(trakt.isImporting)

                if let summary = trakt.lastImport {
                    importStatus(summary)
                }

                if trakt.pendingMutationCount > 0 {
                    Button {
                        trakt.retryPendingMutations()
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 22, weight: .medium))
                            Text("Retry Pending Trakt Changes")
                            Spacer(minLength: 0)
                            if trakt.isSyncingMutations {
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(trakt.isSyncingMutations)

                    (trakt.mutationSyncError.map { Text($0) }
                        ?? Text("\(trakt.pendingMutationCount) Trakt changes waiting to sync."))
                        .font(.system(size: 22))
                        .foregroundStyle(trakt.mutationSyncError != nil ? .red : .secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Button {
                    Task { await trakt.disconnect() }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 22, weight: .medium))
                        Text("Disconnect")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
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
