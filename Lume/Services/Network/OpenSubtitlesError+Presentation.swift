import Foundation

extension OpenSubtitlesError {
    /// Shared by search, download and sign-in. Known service failures use our
    /// translated guidance; transport/filesystem errors keep their explanation.
    static func presentationMessage(for error: any Error) -> String {
        if let error = error as? OpenSubtitlesError { return String(localized: error.message) }
        return error.localizedDescription
    }
}
