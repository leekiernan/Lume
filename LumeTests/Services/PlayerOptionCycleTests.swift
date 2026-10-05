@testable import Lume
import Testing

/// The tvOS option rows advance through their choices with `PlayerOptionCycle`,
/// including the optional-setting "Off" slot and the reset for a stored value
/// that no longer names a case.
struct PlayerOptionCycleTests {
    @Test func `string enum wraps to the first case`() throws {
        let last = try #require(LiveSurfMode.allCases.last?.rawValue)
        let first = try #require(LiveSurfMode.allCases.first?.rawValue)
        #expect(PlayerOptionCycle.next(last, in: LiveSurfMode.self) == first)
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

    @Test func `unknown value without a fallback resets to the first choice`() throws {
        let first = try #require(ExternalPlayerScope.allCases.first?.rawValue)
        #expect(PlayerOptionCycle.next("bogus", in: ExternalPlayerScope.self)
            == first)
    }

    @Test func `off value leads the cycle and follows the last case`() throws {
        let players = ExternalPlayer.allCases.map(\.rawValue)
        #expect(PlayerOptionCycle.next("", in: ExternalPlayer.self, offValue: "") == players.first)
        #expect(try PlayerOptionCycle.next(#require(players.last), in: ExternalPlayer.self, offValue: "") == "")
        #expect(PlayerOptionCycle.next("bogus", in: ExternalPlayer.self, offValue: "") == "")
    }

    @Test func `integer presets advance in declared order then wrap`() {
        let values = [0, 3, 10]
        #expect(PlayerOptionCycle.next(0, in: values) == 3)
        #expect(PlayerOptionCycle.next(3, in: values) == 10)
        #expect(PlayerOptionCycle.next(10, in: values) == 0)
        #expect(PlayerOptionCycle.next(99, in: values) == 0)
    }

    @Test func `empty and single integer preset lists remain safe`() {
        #expect(PlayerOptionCycle.next(99, in: []) == 99)
        #expect(PlayerOptionCycle.next(3, in: [3]) == 3)
        #expect(PlayerOptionCycle.next(99, in: [3]) == 3)
    }

    @Test func `integer enum choices use raw values rather than offsets`() {
        #expect(PlayerOptionCycle.next(4, in: IntegerOptions.self) == 8)
        #expect(PlayerOptionCycle.next(8, in: IntegerOptions.self) == 4)
        #expect(PlayerOptionCycle.next(99, in: IntegerOptions.self) == 4)
    }

    private enum IntegerOptions: Int, CaseIterable {
        case first = 4
        case second = 8
    }
}
