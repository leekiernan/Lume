@testable import Lume
import Testing

nonisolated struct RequestTokenTests {
    @Test func `fresh requests have distinct identities even with no query key`() {
        let tokens = (0 ..< 100).map { _ in RequestToken() }
        #expect(Set(tokens).count == tokens.count)
    }

    @Test func `copying a request preserves its identity`() {
        let token = RequestToken()
        let copy = token
        #expect(copy == token)
        #expect(Set([token, copy]).count == 1)
        #expect(copy != RequestToken())
    }

    @Test func `request identity can cross an actor boundary without changing`() async {
        let token = RequestToken()
        let returned = await Task.detached { token }.value
        #expect(returned == token)
    }
}
