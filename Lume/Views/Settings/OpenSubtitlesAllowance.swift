import Foundation

nonisolated enum OpenSubtitlesAllowance {
    static func summary(remaining: Int?, allowed: Int?) -> String {
        if let remaining { return String(localized: "\(remaining) subtitle downloads left today.") }
        if let allowed, allowed > 0 { return String(localized: "Your account allows \(allowed) subtitle downloads a day.") }
        return String(localized: "Search for subtitles from the player's subtitle menu while a movie or episode is playing.")
    }
}
