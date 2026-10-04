import Foundation
@testable import Lume
import Testing

struct NetworkIdentityHelpersTests {
    @Test(arguments: [
        ("https://example.com/", "https://example.com"),
        ("https://example.com/base/", "https://example.com/base"),
        ("https://example.com/base//", "https://example.com/base/"),
        ("https://example.com/base", "https://example.com/base"),
        ("https://example.com/base/?token=x#part", "https://example.com/base/?token=x#part")
    ])
    func `both media-server clients retain their normalization`(_ input: String, _ expected: String) throws {
        let url = try #require(URL(string: input))
        #expect(JellyfinClient.normalizedServerURL(url).absoluteString == expected)
        #expect(PlexClient.normalizedServerURL(url).absoluteString == expected)
    }

    @Test func `webdav parser and walk keys retain path spelling semantics`() {
        #expect(WebDAVPathIdentity.key("https://example.com/My%20Files/?token=x") == "https://example.com/My Files")
        #expect(WebDAVPathIdentity.key("https://example.com/My Files") == "https://example.com/My Files")
        #expect(WebDAVPathIdentity.key("https://example.com/my%20files/") != WebDAVPathIdentity.key("https://example.com/My%20Files/"))
        #expect(WebDAVPathIdentity.key("https://example.com/a%2Fb/") == "https://example.com/a/b")
        #expect(WebDAVPathIdentity.key("https://example.com/base//") == "https://example.com/base/")
    }

    @Test func `digest namespaces preserve existing keys and remain independent`() throws {
        let suite = "digest-helpers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let m3u = PlaylistDigestStore(namespace: "sync.m3uDigest")
        let webdav = PlaylistDigestStore(namespace: "sync.webdavDigest")
        #expect(m3u.key(playlistId: id) == M3UDigestStore.key(playlistId: id))
        #expect(webdav.key(playlistId: id) == WebDAVDigestStore.key(playlistId: id))
        defaults.set("legacy", forKey: "sync.m3uDigest.\(id.uuidString)")
        #expect(m3u.digest(playlistId: id, defaults: defaults) == "legacy")
        webdav.store("tree", playlistId: id, defaults: defaults)
        m3u.remove(playlistId: id, defaults: defaults)
        #expect(m3u.digest(playlistId: id, defaults: defaults) == nil)
        #expect(webdav.digest(playlistId: id, defaults: defaults) == "tree")
        webdav.remove(playlistId: id, defaults: defaults)
        #expect(webdav.digest(playlistId: id, defaults: defaults) == nil)
    }
}
