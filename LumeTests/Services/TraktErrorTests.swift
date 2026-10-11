@testable import Lume
import Testing

struct TraktErrorTests {
    @Test(arguments: [
        TraktError.notConfigured, .invalidResponse, .server(422), .decoding, .notAuthenticated,
        .authorizationPending, .slowDown, .codeExpired, .codeDenied, .codeUsed
    ])
    func `every Trakt error has an explicit diagnostic`(error: TraktError) {
        #expect(LogRedaction.describe(error) == "TraktError: \(error.logDescription)")
        #expect(!error.logDescription.isEmpty)
        #expect(!LogRedaction.describe(error).contains("operation couldn’t be completed"))
    }
}
