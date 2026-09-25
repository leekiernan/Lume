@testable import Lume
import Testing

/// The tvOS option rows advance through their choices with `PlayerOptionCycle`,
/// including the optional-setting "Off" slot and the reset for a stored value
/// that no longer names a case.
struct PlayerOptionCycleTests {
    @Test func `string enum wraps to the first case`() throws {
        let last = try #require(LiveSurfMode.allCases.last?.rawValue)
        #expect(PlayerOptionCycle.next(last, in: LiveSurfMode.self) == LiveSurfMode.allCases.first!.rawValue)
    }

    @Test func `unknown value resets to the fallback`() {
        #expect(
            PlayerOptionCycle.next("bogus", in: ExternalPlayerScope.self, fallback: .default)
                == ExternalPlayerScope.default.rawValue
        )
        #expect(
            PlayerOptionCycle.next("bogus", in: LiveSurfMode.self, fallback: .default)
                == LiveSurfMode.default.rawValue
        )
    }

    @Test func `unknown value without a fallback resets to the first choice`() {
        #expect(PlayerOptionCycle.next("bogus", in: ExternalPlayerScope.self)
            == ExternalPlayerScope.allCases.first!.rawValue)
    }

    @Test func `off value leads the cycle and follows the last case`() throws {
        let players = ExternalPlayer.allCases.map(\.rawValue)
        #expect(PlayerOptionCycle.next("", in: ExternalPlayer.self, offValue: "") == players.first)
        #expect(try PlayerOptionCycle.next(#require(players.last), in: ExternalPlayer.self, offValue: "") == "")
        #expect(PlayerOptionCycle.next("bogus", in: ExternalPlayer.self, offValue: "") == "")
    }
}
