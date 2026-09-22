import Foundation
@testable import Lume
import Testing

// MARK: - SimklTokens (pure logic)

struct SimklTokensTests {
    private func makeTokens(
        accessToken: String = "access",
        refreshToken: String = "refresh",
        issuedAt: TimeInterval = 1000,
        expiresIn: TimeInterval = 500,
        scope: String? = "media:read media:write",
        tokenType: String? = "Bearer"
    ) -> SimklTokens {
        SimklTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            issuedAt: issuedAt,
            expiresIn: expiresIn,
            scope: scope,
            tokenType: tokenType
        )
    }

    @Test func `expiry date is issued plus lifetime`() {
        let tokens = makeTokens(issuedAt: 1000, expiresIn: 500)
        #expect(tokens.expiryDate == Date(timeIntervalSince1970: 1500))
    }

    @Test func `needs refresh when already expired`() {
        let issuedAt = Date().timeIntervalSince1970 - 14 * 24 * 60 * 60
        let tokens = makeTokens(issuedAt: issuedAt, expiresIn: 7 * 24 * 60 * 60)
        #expect(tokens.needsRefresh == true)
    }

    @Test func `needs refresh when within a day of expiry`() {
        // Expires in 12 hours — inside the one-day refresh window.
        let issuedAt = Date().timeIntervalSince1970
        let tokens = makeTokens(issuedAt: issuedAt, expiresIn: 12 * 60 * 60)
        #expect(tokens.needsRefresh == true)
    }

    @Test func `does not need refresh when far from expiry`() {
        // A fresh seven-day token — well outside the refresh window.
        let issuedAt = Date().timeIntervalSince1970
        let tokens = makeTokens(issuedAt: issuedAt, expiresIn: 7 * 24 * 60 * 60)
        #expect(tokens.needsRefresh == false)
    }

    @Test func `codable round trip preserves values`() throws {
        let tokens = makeTokens()
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(SimklTokens.self, from: data)
        #expect(decoded == tokens)
    }

    @Test func `codable round trip with nil metadata`() throws {
        let tokens = makeTokens(scope: nil, tokenType: nil)
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(SimklTokens.self, from: data)
        #expect(decoded == tokens)
        #expect(decoded.scope == nil)
        #expect(decoded.tokenType == nil)
    }

    @Test func `equatable distinguishes different tokens`() {
        let base = makeTokens()
        #expect(base != makeTokens(accessToken: "different"))
        #expect(base != makeTokens(refreshToken: "different"))
        #expect(base != makeTokens(expiresIn: 999))
        #expect(base == makeTokens())
    }
}

// MARK: - Cloud merge values

struct SimklCredentialValuesTests {
    private func makeTokens(accessToken: String, refreshToken: String, issuedAt: TimeInterval) -> SimklTokens {
        SimklTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            issuedAt: issuedAt,
            expiresIn: 604_800,
            scope: "media:read media:write",
            tokenType: "Bearer"
        )
    }

    @Test func `shadow encoding contains a fingerprint but no OAuth secrets`() throws {
        let value = SimklCredentialValues(tokens: makeTokens(
            accessToken: "secret-access",
            refreshToken: "secret-refresh",
            issuedAt: 100
        ))
        let data = try JSONEncoder().encode(value)
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(encoded.contains("fingerprint"))
        #expect(!encoded.contains("secret-access"))
        #expect(!encoded.contains("secret-refresh"))
        #expect(try JSONDecoder().decode(SimklCredentialValues.self, from: data) == value)
    }

    @Test func `a concurrent refresh keeps the newest issued token`() {
        let older = SimklCredentialValues(tokens: makeTokens(accessToken: "older", refreshToken: "older-refresh", issuedAt: 100))
        let newer = SimklCredentialValues(tokens: makeTokens(accessToken: "newer", refreshToken: "newer-refresh", issuedAt: 200))
        #expect(SimklCredentialValues.reconcile(local: newer, cloud: older, shadow: nil) == .writeBoth(newer))
    }

    @Test func `a concurrent disconnect wins over a token refresh`() {
        let original = SimklCredentialValues(tokens: makeTokens(accessToken: "original", refreshToken: "original-refresh", issuedAt: 100))
        let refreshed = SimklCredentialValues(tokens: makeTokens(accessToken: "refreshed", refreshToken: "refreshed-refresh", issuedAt: 200))
        #expect(SimklCredentialValues.reconcile(local: nil, cloud: refreshed, shadow: original) == .pushToCloud(nil))
    }
}

// MARK: - SimklTokenStore (keychain)

/// Serialized because every test touches the single shared keychain item
/// (service + account are constant), so concurrent runs would race.
@Suite(.serialized)
struct SimklTokenStoreTests {
    init() {
        // Start every test from a known-empty keychain slot.
        SimklTokenStore.clear()
    }

    private func makeTokens(accessToken: String = "access-token") -> SimklTokens {
        SimklTokens(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            issuedAt: 1_700_000_000,
            expiresIn: 604_800,
            scope: "media:read media:write",
            tokenType: "Bearer"
        )
    }

    @Test func `load returns nil when nothing stored`() {
        #expect(SimklTokenStore.load() == nil)
        #expect(SimklTokenStore.storedTokens() == .notSet)
    }

    @Test func `save then load returns the same tokens`() {
        let tokens = makeTokens()
        #expect(SimklTokenStore.save(tokens) == true)
        #expect(SimklTokenStore.load() == tokens)
        SimklTokenStore.clear()
    }

    @Test func `save overwrites an existing token set`() {
        #expect(SimklTokenStore.save(makeTokens(accessToken: "first")) == true)
        // Second save exercises the SecItemUpdate path.
        let updated = makeTokens(accessToken: "second")
        #expect(SimklTokenStore.save(updated) == true)
        #expect(SimklTokenStore.load() == updated)
        SimklTokenStore.clear()
    }

    @Test func `clear removes stored tokens`() {
        #expect(SimklTokenStore.save(makeTokens()) == true)
        #expect(SimklTokenStore.clear() == true)
        #expect(SimklTokenStore.load() == nil)
    }

    @Test func `clear succeeds when nothing is stored`() {
        // A missing item is the desired end state, so this reports success.
        #expect(SimklTokenStore.clear() == true)
    }
}
