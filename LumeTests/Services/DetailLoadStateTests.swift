@testable import Lume
import Testing

struct DetailLoadStateTests {
    @Test func `one detail lane cannot consume another lane's request`() {
        var initial = DetailLoadState(isBlocking: true)
        var optional = DetailLoadState()
        let request = initial.begin()
        let other = optional.begin()
        let accepted4 = initial.finish(other)
        #expect(!accepted4)
        #expect(initial.owns(request))
        let accepted5 = optional.finish(request)
        #expect(!accepted5)
        #expect(optional.owns(other))
    }

    @Test func `a new title lane cannot reuse a previous request identity`() {
        var state = DetailLoadState()
        let previous = state.begin()
        state = DetailLoadState(isBlocking: true)
        let current = state.begin()
        #expect(current != previous)
        #expect(!state.owns(previous))
    }

    @Test func `stale completion cannot settle a replacement detail load`() {
        var state = DetailLoadState(isBlocking: true)
        let old = state.begin()
        let current = state.begin()
        let acceptedOld = state.finish(old)
        #expect(!acceptedOld)
        #expect(state.isLoading)
        #expect(state.isBlocking)
        let accepted = state.finish(current)
        #expect(accepted)
        #expect(!state.isLoading)
        #expect(!state.isBlocking)
    }

    @Test func `dismissal rejects late completion and permits a new request`() {
        var state = DetailLoadState(isBlocking: true)
        let old = state.begin()
        state.invalidate()
        #expect(!state.owns(old))
        let new = state.begin()
        #expect(state.owns(new))
        #expect(new != old)
        let rejected = state.finish(old)
        #expect(!rejected)
        #expect(state.isBlocking)
    }

    @Test func `cached detail refresh stays nonblocking`() {
        var state = DetailLoadState()
        let request = state.begin()
        #expect(state.isLoading)
        #expect(!state.isBlocking)
        state.finish(request)
        #expect(!state.isBlocking)
    }

    @Test func `episode and collection lanes do not settle initial detail work`() {
        var detail = DetailLoadState(isBlocking: true)
        var optional = DetailLoadState()
        let request = detail.begin()
        let refresh = optional.begin()
        optional.finish(refresh)
        #expect(detail.owns(request))
        #expect(detail.isBlocking)
        detail.finish(request)
        #expect(!detail.isBlocking)
    }
}
