//
//  TVSimklIntegrationView.swift
//  Lume
//
//  The tvOS Integrations pane content for Simkl, shown inside SettingsView's
//  detail column. Drives the OAuth device flow with a scannable QR code (Apple
//  TV can't open a browser), and surfaces the connected account.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVSimklIntegrationView: View {
        @State private var simkl = SimklService.shared
        /// Simkl is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Simkl")

                if simkl.isConnected {
                    connected
                } else if let code = simkl.pendingCode {
                    deviceCode(code)
                } else {
                    connect
                }
            }
            .paywall(isPresented: $showPaywall, highlight: .simkl)
            .onDisappear {
                // Stop polling if the user leaves the pane mid-connect.
                if !simkl.isConnected {
                    simkl.cancelConnect()
                }
            }
        }

        private var connect: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync the movies and episodes you watch to Simkl, and surface your Simkl watchlist on Home.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    if premium.isPremium {
                        simkl.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: premium.isPremium ? "link" : "crown")
                            .font(.system(size: 22, weight: .medium))
                        Text("Connect Simkl Account")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(simkl.isConnecting)

                if let error = simkl.connectionError {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
        }

        private func deviceCode(_ code: SimklDeviceCode) -> some View {
            TrackerDeviceCodePanel(provider: .simkl, code: code.userCode, activationURL: SimklClient.activationURL(for: code)) {
                simkl.cancelConnect()
            }
        }

        private var connected: some View {
            VStack(alignment: .leading, spacing: 16) {
                TrackerConnectedAccount(username: simkl.username)

                Text("Watched movies and episodes sync to your Simkl history. Import marks titles you've already watched on Simkl as watched here.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    Task { await simkl.importWatched(into: modelContext) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 22, weight: .medium))
                        Text("Import Watched from Simkl")
                        Spacer(minLength: 0)
                        if simkl.isImporting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(simkl.isImporting)

                if let summary = simkl.lastImport {
                    importStatus(summary)
                }

                Button {
                    Task { await simkl.disconnect() }
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

        private func importStatus(_ summary: SimklImportSummary) -> some View {
            TrackerImportStatus(
                provider: .simkl, movies: summary.moviesMarked, episodes: summary.episodesMarked,
                queuedShows: summary.showsQueued, failed: summary.failed
            )
        }
    }

#endif
