import Foundation
@testable import Lume
import Testing

struct OpenSubtitlesAllowanceTests {
    @Test func `remaining quota including zero wins over the account allowance`() {
        #expect(OpenSubtitlesAllowance.summary(remaining: 0, allowed: 10) == String(localized: "\(0) subtitle downloads left today."))
        #expect(OpenSubtitlesAllowance.summary(remaining: 3, allowed: nil) == String(localized: "\(3) subtitle downloads left today."))
    }

    @Test func `unknown remaining quota shows a positive allowance or the existing guidance`() {
        #expect(OpenSubtitlesAllowance.summary(remaining: nil, allowed: 10) == String(localized: "Your account allows \(10) subtitle downloads a day."))
        let guidance = String(localized: "Search for subtitles from the player's subtitle menu while a movie or episode is playing.")
        #expect(OpenSubtitlesAllowance.summary(remaining: nil, allowed: nil) == guidance)
        #expect(OpenSubtitlesAllowance.summary(remaining: nil, allowed: 0) == guidance)
    }
}
