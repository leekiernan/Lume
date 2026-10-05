//
//  OpenSubtitlesIntegrationView.swift
//  Lume
//
//  The OpenSubtitles account surface. Searching works anonymously, but
//  downloading needs a user token — `/download` answers 401 without one and the
//  daily allowance is counted per account — so the viewer signs in with their
//  own opensubtitles.com credentials.
//
//  `OpenSubtitlesSignInSection` is shared between this settings screen and the
//  in-player search sheet, so a viewer who hits the feature mid-playback can
//  sign in without leaving the player.
//

import SwiftUI

// MARK: - Shared sign-in / account section

struct OpenSubtitlesSignInSection: View {
    /// Off on the Settings screen, whose navigation title already says
    /// OpenSubtitles; on in the in-player sheet, which is titled "Subtitles".
    var showsHeader = true

    @State private var service = OpenSubtitlesService.shared
    @State private var username = ""
    @State private var password = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        if service.isSignedIn {
            accountSection
        } else {
            signInSection
        }
    }

    private var signInSection: some View {
        Section {
            TextField("Username", text: $username)
                .usernameEntry()
            SecureField("Password", text: $password)
                .textContentType(.password)

            Button {
                Task { await service.signIn(username: username, password: password) }
            } label: {
                SettingsActionLabel(title: "Sign In", systemImage: "person.crop.circle.badge.checkmark", isBusy: service.isSigningIn)
            }
            .disabled(service.isSigningIn || username.isEmpty || password.isEmpty)

            #if !os(tvOS)
                if let url = URL(string: "https://www.opensubtitles.com/users/sign_up") {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Create an Account", systemImage: "safari")
                    }
                }
            #endif
        } header: {
            if showsHeader { Text("OpenSubtitles") }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in with your free opensubtitles.com account to download subtitles. Searching works without one.")
                Text("Enter your username, not the email address you registered with — OpenSubtitles rejects an email here.")
                if let error = service.signInError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signed In")
                    if let username = service.username {
                        Text(username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Button(role: .destructive) {
                Task { await service.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            if showsHeader { Text("OpenSubtitles") }
        } footer: {
            Text(OpenSubtitlesAllowance.summary(remaining: service.remainingDownloads, allowed: service.allowedDownloads))
        }
    }
}

// MARK: - Settings screen (iOS / macOS / visionOS)

#if !os(tvOS)

    struct OpenSubtitlesIntegrationView: View {
        @State private var service = OpenSubtitlesService.shared

        var body: some View {
            List {
                OpenSubtitlesSignInSection(showsHeader: false)

                Section {
                    NavigationLink {
                        SubtitleLanguagePicker()
                    } label: {
                        LabeledContent {
                            Text(languageSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } label: {
                            Label("Subtitle Languages", systemImage: "globe")
                        }
                    }
                } footer: {
                    Text("Subtitle search only returns these languages.")
                }
            }
            .platformNavigationTitle("OpenSubtitles")
        }

        private var languageSummary: String {
            service.preferredLanguages
                .map { TrackLanguageMatcher.displayName(for: $0) }
                .joined(separator: ", ")
        }
    }

#endif
