//
//  SimklIntegrationView.swift
//  Lume
//
//  The iOS/macOS Simkl integration screen (the tvOS surface is
//  `TVSimklIntegrationView`, shown in SettingsView's Integrations pane). Drives
//  the OAuth device flow: shows the activation code with a one-tap link to the
//  pre-filled simkl.com/pin page, polls in the background, and surfaces the
//  connected account with import and disconnect actions.
//

#if !os(tvOS)

    import SwiftData
    import SwiftUI

    struct SimklIntegrationView: View {
        @State private var simkl = SimklService.shared
        /// Simkl is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            List {
                if simkl.isConnected {
                    connectedSection
                } else if let code = simkl.pendingCode {
                    deviceCodeSection(code)
                } else {
                    connectSection
                }
            }
            .platformNavigationTitle("Simkl")
            .paywall(isPresented: $showPaywall, highlight: .simkl)
            .onDisappear {
                // Stop polling if the user backs out mid-connect.
                if !simkl.isConnected {
                    simkl.cancelConnect()
                }
            }
        }

        // MARK: - Connect

        private var connectSection: some View {
            Section {
                Button {
                    if premium.isPremium {
                        simkl.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    Label("Connect Simkl Account", systemImage: premium.isPremium ? "link" : "crown")
                }
                .disabled(simkl.isConnecting)
            } header: {
                Text("Simkl")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync the movies and episodes you watch to Simkl, and surface your Simkl watchlist on Home.")
                    if let error = simkl.connectionError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }

        // MARK: - Device code

        private func deviceCodeSection(_ code: SimklDeviceCode) -> some View {
            Section {
                TrackerDeviceCodePanel(provider: .simkl, code: code.userCode, activationURL: SimklClient.activationURL(for: code)) {
                    simkl.cancelConnect()
                }
            }
        }

        // MARK: - Connected

        private var connectedSection: some View {
            Section {
                TrackerConnectedAccount(username: simkl.username)

                Button {
                    Task { await simkl.importWatched(into: modelContext) }
                } label: {
                    HStack {
                        Label("Import Watched from Simkl", systemImage: "arrow.down.circle")
                        if simkl.isImporting {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(simkl.isImporting)

                Button(role: .destructive) {
                    Task { await simkl.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "link.badge.plus")
                }
            } header: {
                Text("Simkl")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watched movies and episodes sync to your Simkl history. Import marks titles you've already watched on Simkl as watched here.")
                    if let summary = simkl.lastImport {
                        importStatus(summary)
                    }
                }
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
