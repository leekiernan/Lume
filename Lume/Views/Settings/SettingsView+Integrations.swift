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
                        IntegrationSettingsLabel(
                            title: "Trakt", symbol: "arrow.trianglehead.2.clockwise.rotate.90.circle",
                            detail: trakt.isConnected ? (trakt.username.map { Text(verbatim: "@\($0)") } ?? Text("Connected")) : nil
                        )
                    }
                }

                if simkl.isConfigured {
                    NavigationLink {
                        SimklIntegrationView()
                    } label: {
                        IntegrationSettingsLabel(
                            title: "Simkl", symbol: "arrow.trianglehead.2.clockwise.rotate.90.circle",
                            detail: simkl.isConnected ? (simkl.username.map { Text(verbatim: "@\($0)") } ?? Text("Connected")) : nil
                        )
                    }
                }

                if openSubtitles.isConfigured {
                    NavigationLink {
                        OpenSubtitlesIntegrationView()
                    } label: {
                        IntegrationSettingsLabel(title: "OpenSubtitles", symbol: "captions.bubble", detail: openSubtitles.username.map { Text(verbatim: $0) })
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
            if simkl.isConfigured {
                sentences.append(String(localized: "Show your Simkl watchlist on Home."))
            }
            if openSubtitles.isConfigured {
                sentences.append(String(localized: "Download subtitles for anything that ships without them."))
            }
            return sentences.joined(separator: " ")
        }
    }

    private struct IntegrationSettingsLabel: View {
        let title: LocalizedStringKey
        let symbol: String
        /// A username is shown as is; the "Connected" fallback is localised.
        let detail: Text?

        var body: some View {
            LabeledContent {
                if let detail {
                    detail.font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Label(title, systemImage: symbol)
            }
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
