//
//  TVOpenSubtitlesIntegrationView.swift
//  Lume
//
//  The tvOS Integrations pane content for OpenSubtitles, shown inside
//  SettingsView's detail column alongside Trakt. Sign-in is a plain
//  username/password pair — OpenSubtitles has no device flow, so unlike Trakt
//  there is nothing to scan.
//

#if os(tvOS)

    import SwiftUI

    struct TVOpenSubtitlesIntegrationView: View {
        /// Drops the explanatory paragraph, keeping only the actionable hint.
        /// The in-player overlay raises this above the search results, where a
        /// two-paragraph preamble pushes what the viewer came for off-screen.
        var isCompact = false

        @State private var service = OpenSubtitlesService.shared
        @State private var username = ""
        @State private var password = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("OpenSubtitles")

                if service.isSignedIn {
                    signedIn
                } else {
                    signIn
                }
            }
        }

        private var signIn: some View {
            VStack(alignment: .leading, spacing: 16) {
                if !isCompact {
                    Text("Sign in with your free opensubtitles.com account to download subtitles for movies and episodes from the player's subtitle menu.")
                        .font(.system(size: TVSettingsMetrics.statusFontSize))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Text("Enter your username, not the email address you registered with — OpenSubtitles rejects an email here.")
                    .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                TVSettingsField(
                    title: "Username",
                    placeholder: "Username",
                    text: $username,
                    contentType: .username
                )

                TVSettingsField(
                    title: "Password",
                    placeholder: "Password",
                    text: $password,
                    isSecure: true,
                    contentType: .password
                )

                Button {
                    Task { await service.signIn(username: username, password: password) }
                } label: {
                    SettingsActionLabel(title: "Sign In", systemImage: "person.crop.circle.badge.checkmark", isBusy: service.isSigningIn)
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(service.isSigningIn || username.isEmpty || password.isEmpty)

                if let error = service.signInError {
                    Text(error)
                        .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
        }

        private var signedIn: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsValueRow("Signed In", value: service.username ?? "—")

                Text(OpenSubtitlesAllowance.summary(remaining: service.remainingDownloads, allowed: service.allowedDownloads))
                    .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button(role: .destructive) {
                    Task { await service.signOut() }
                } label: {
                    SettingsActionLabel(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
            }
        }
    }

#endif
