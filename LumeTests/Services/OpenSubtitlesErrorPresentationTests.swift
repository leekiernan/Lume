import Foundation
@testable import Lume
import Testing

@MainActor
struct OpenSubtitlesErrorPresentationTests {
    @Test func `every service error retains its translated guidance across presentation paths`() {
        let errors: [OpenSubtitlesError] = [
            .notConfigured, .invalidResponse, .notAuthenticated, .invalidCredentials,
            .quotaExceeded, .rateLimited, .server(503), .decoding
        ]
        for error in errors {
            #expect(OpenSubtitlesError.presentationMessage(for: error) == String(localized: error.message))
        }
        #expect(OpenSubtitlesError.presentationMessage(for: OpenSubtitlesError.quotaExceeded)
            != OpenSubtitlesError.presentationMessage(for: OpenSubtitlesError.rateLimited))
    }

    @Test func `unrecognised transport or filesystem failures retain their localized explanation`() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection lost"])
        #expect(OpenSubtitlesError.presentationMessage(for: error) == "Connection lost")
        let transport = URLError(.notConnectedToInternet)
        #expect(OpenSubtitlesError.presentationMessage(for: transport) == transport.localizedDescription)
    }
}
