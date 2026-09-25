//
//  SettingsView+Integrations.swift
//  Lume
//
//  The Trakt / Simkl / OpenSubtitles entries in the main list, and their tvOS
//  detail pane. Trakt and Simkl are two alternatives for the same job —
//  scrobbling and watched-history sync — so they're offered the same way: the
//  same row shape, the same icon, a NavigationLink only once configured.
//

import SwiftUI

extension SettingsView {
    /// Whether the build has credentials for at least one integration — the
    /// Integrations section (iOS / macOS) and sidebar category (tvOS) are
    /// hidden otherwise.
    var hasAnyIntegration: Bool {
        trakt.isConfigured || simkl.isConfigured || openSubtitles.isConfigured
    }
}

#if !os(tvOS)

    extension SettingsView {
        var integrationsSection: some View {
            Section {
                if trakt.isConfigured {
                    NavigationLink {
                        TraktIntegrationView()
                    } label: {
                        HStack {
                            Label("Trakt", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.circle")
                            Spacer()
                            if trakt.isConnected {
                                Text(trakt.username.map { "@\($0)" } ?? "Connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if simkl.isConfigured {
                    NavigationLink {
                        SimklIntegrationView()
                    } label: {
                        HStack {
                            Label("Simkl", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.circle")
                            Spacer()
                            if simkl.isConnected {
                                Text(simkl.username.map { "@\($0)" } ?? "Connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if openSubtitles.isConfigured {
                    NavigationLink {
                        OpenSubtitlesIntegrationView()
                    } label: {
                        HStack {
                            Label("OpenSubtitles", systemImage: "captions.bubble")
                            Spacer()
                            if let username = openSubtitles.username {
                                Text(username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text(integrationsFooter)
            }
        }

        /// One sentence per configured integration, so the footer never
        /// promises a service this build hides.
        private var integrationsFooter: String {
            var sentences: [String] = []
            if trakt.isConfigured || simkl.isConfigured {
                sentences.append(String(localized: "Sync watched movies and episodes."))
            }
            if trakt.isConfigured {
                sentences.append(String(localized: "Show your Trakt watchlist on Home."))
            }
            if openSubtitles.isConfigured {
                sentences.append(String(localized: "Download subtitles for anything that ships without them."))
            }
            return sentences.joined(separator: " ")
        }
    }

#else

    extension SettingsView {
        var tvIntegrationsDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                if trakt.isConfigured {
                    TVTraktIntegrationView()
                }
                if simkl.isConfigured {
                    TVSimklIntegrationView()
                }
                if openSubtitles.isConfigured {
                    TVOpenSubtitlesIntegrationView()
                }
            }
        }
    }

#endif
