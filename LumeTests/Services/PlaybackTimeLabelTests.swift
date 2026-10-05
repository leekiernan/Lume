import Foundation
@testable import Lume
import Testing

struct PlaybackTimeLabelTests {
    @Test func `clock labels truncate subseconds and preserve hour boundaries`() {
        #expect(PlaybackTimeLabel.clock(0) == "0:00")
        #expect(PlaybackTimeLabel.clock(59.99) == "0:59")
        #expect(PlaybackTimeLabel.clock(60) == "1:00")
        #expect(PlaybackTimeLabel.clock(3599.99) == "59:59")
        #expect(PlaybackTimeLabel.clock(3600) == "1:00:00")
        #expect(PlaybackTimeLabel.clock(3725.9) == "1:02:05")
        #expect(PlaybackTimeLabel.clock(360_000) == "100:00:00")
    }

    @Test func `invalid and unrepresentable engine timestamps safely read as zero`() {
        for position in [-1, Double.nan, .infinity, -.infinity, Double(Int.max), Double.greatestFiniteMagnitude] {
            #expect(PlaybackTimeLabel.clock(position) == "0:00")
            #expect(PlaybackTimeLabel.localized(position) == PlaybackTimeLabel.localized(0))
        }
    }

    @Test func `localized badges retain native duration formatting independently of scrubber labels`() {
        for identifier in ["en_GB", "fr_FR", "ar_EG"] {
            let locale = Locale(identifier: identifier)
            for seconds in [0.0, 754.9, 3725.9] {
                let clamped = seconds.rounded(.down)
                let pattern: Duration.TimeFormatStyle.Pattern = clamped >= 3600 ? .hourMinuteSecond : .minuteSecond
                let native = Duration.seconds(clamped).formatted(.time(pattern: pattern).locale(locale))
                #expect(PlaybackTimeLabel.localized(seconds, locale: locale) == native)
            }
        }
    }
}
