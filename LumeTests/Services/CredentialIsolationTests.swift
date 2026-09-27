import Foundation
@testable import Lume
import Testing

/// The tripwire for `CredentialIsolation`: if the bundle's load-time
/// constructor ever stops running, this fails instead of the next credential
/// test quietly using the developer's real keychain.
@MainActor
struct CredentialIsolationTests {
    @Test func `the process-wide credential backend is the in-memory stand-in`() {
        #expect(CredentialBackend.scoped == nil)
        let storage = CredentialBackend.current.storage as? InMemoryCredentialStorage
        #expect(storage === CredentialIsolation.processStorage)
        #expect(!(CredentialBackend.current.storage is KeychainCredentialStorage))
        #expect(CredentialBackend.current.defaults !== UserDefaults.standard)
    }

    @Test func `a scoped backend is private to its test and starts empty`() async {
        await withIsolatedCredentials { storage in
            #expect(CredentialBackend.current.storage as? InMemoryCredentialStorage === storage)
            #expect(TraktTokenStore.storedTokens() == .notSet)
            #expect(SimklTokenStore.storedTokens() == .notSet)
            #expect(ParentalControlsStore.storedHash() == .notSet)
            #expect(OpenSubtitlesSessionStore.load() == nil)
            #expect(ParentalControlsStore.save(pin: "1234"))
            #expect(storage.storedData(service: "bilipp.Lume.parental") != nil)
        }
    }
}
