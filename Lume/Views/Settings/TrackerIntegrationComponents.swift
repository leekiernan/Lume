import SwiftUI

/// Presentation capabilities only. OAuth, imports and durable mutation queues
/// remain provider-owned; shared UI must not imply identical service behavior.
enum TrackerIntegrationPresentation: CaseIterable {
    case trakt
    case simkl

    var supportsInProgressImport: Bool {
        self == .trakt
    }

    var activationAddress: String {
        switch self {
        case .trakt: "trakt.tv/activate"
        case .simkl: "simkl.com/pin"
        }
    }

    var activationInstruction: LocalizedStringKey {
        switch self {
        case .trakt: "Enter this code at trakt.tv/activate"
        case .simkl: "Enter this code at simkl.com/pin"
        }
    }

    var openLabel: LocalizedStringKey {
        switch self {
        case .trakt: "Open trakt.tv/activate"
        case .simkl: "Open simkl.com/pin"
        }
    }

    var importFailure: LocalizedStringKey {
        switch self {
        case .trakt: "Couldn't import from Trakt. Please try again."
        case .simkl: "Couldn't import from Simkl. Please try again."
        }
    }
}

struct TrackerDeviceCodePanel: View {
    let provider: TrackerIntegrationPresentation
    let code: String
    let activationURL: URL?
    let cancel: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(tvOS)
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("On your phone or computer, go to")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                    Text(verbatim: provider.activationAddress)
                        .font(.system(size: 30, weight: .semibold))
                    Text("Enter this code")
                        .font(.system(size: 24)).foregroundStyle(.secondary).padding(.top, 8)
                    Text(verbatim: code)
                        .font(.system(size: 56, weight: .bold, design: .monospaced)).tracking(6)
                    waiting
                        .font(.system(size: 22)).padding(.top, 8)
                    Button("Cancel", action: cancel)
                        .buttonStyle(TVSettingsActionButtonStyle()).padding(.top, 8)
                }
                if let activationURL {
                    VStack(spacing: 12) {
                        QRCodeView(string: activationURL.absoluteString)
                            .frame(width: 240, height: 240).background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text("Scan to open").font(.system(size: 20)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding).padding(.top, 8)
        #else
            VStack(spacing: 16) {
                Text(provider.activationInstruction).font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .tracking(4).textSelection(.enabled)
                if let activationURL {
                    Button { openURL(activationURL) } label: {
                        Label(provider.openLabel, systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    QRCodeView(string: activationURL.absoluteString)
                        .frame(width: 160, height: 160).padding(.top, 4)
                }
                waiting.font(.footnote).padding(.top, 4)
                Button("Cancel", role: .cancel, action: cancel)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        #endif
    }

    private var waiting: some View {
        HStack(spacing: waitingSpacing) {
            ProgressView()
            Text("Waiting for authorization…").foregroundStyle(.secondary)
        }
    }

    private var waitingSpacing: CGFloat {
        #if os(tvOS)
            12
        #else
            8
        #endif
    }
}

struct TrackerConnectedAccount: View {
    let username: String?

    var body: some View {
        #if os(tvOS)
            TVSettingsValueRow("Connected", value: username.map { "@\($0)" } ?? "—")
        #else
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connected")
                    if let username {
                        Text("@\(username)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        #endif
    }
}

struct TrackerImportStatus: View {
    let provider: TrackerIntegrationPresentation
    let movies: Int
    let episodes: Int
    let queuedShows: Int
    var inProgress = 0
    let failed: Bool

    var markedNothing: Bool {
        !failed && movies == 0 && episodes == 0 && queuedShows == 0 && (!provider.supportsInProgressImport || inProgress == 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: statusSpacing) {
            if failed {
                Text(provider.importFailure)
            } else if markedNothing {
                Text("Your watched history is already up to date.")
            } else {
                Text("Imported \(movies) movies and \(episodes) episodes.")
                if provider.supportsInProgressImport, inProgress > 0 {
                    Text("\(inProgress) titles in progress.")
                }
                if queuedShows > 0 {
                    Text("\(queuedShows) shows will be marked the first time you open them.")
                }
            }
        }
        .foregroundStyle(failed ? .red : .green)
        #if os(tvOS)
            .font(.system(size: 22))
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        #endif
    }

    private var statusSpacing: CGFloat {
        #if os(tvOS)
            4
        #else
            2
        #endif
    }
}
