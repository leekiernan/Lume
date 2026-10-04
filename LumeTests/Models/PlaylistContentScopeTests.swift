import Foundation
@testable import Lume
import Testing

struct PlaylistContentScopeTests {
    @Test func `query prefix preserves the catalog UUID namespace`() throws {
        let id = try #require(UUID(uuidString: "a1b2c3d4-1111-2222-3333-444455556666"))
        let prefix = PlaylistContentScope.prefix(for: id)
        #expect(prefix == "A1B2C3D4-1111-2222-3333-444455556666-")
        for suffix in ["movie-42", "series-7", "live-13", "42"] {
            #expect(("\(id.uuidString)-" + suffix).hasPrefix(prefix))
        }
        #expect(!PlaylistContentScope.prefix(for: UUID()).hasPrefix(prefix))
    }

    @Test func `model prefix follows its current id without a stored column`() {
        let playlist = Playlist(name: "Test", serverURL: "", username: "", password: "")
        let first = playlist.contentIDPrefix
        playlist.id = UUID()
        #expect(playlist.contentIDPrefix == PlaylistContentScope.prefix(for: playlist.id))
        #expect(playlist.contentIDPrefix != first)
    }
}
