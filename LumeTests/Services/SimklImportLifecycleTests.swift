import Foundation
@testable import Lume
import SwiftData
import Testing

/// Exercises the real service/client/apply path, with an owned URLSession and
/// suspended history response. No request reaches the network or real keychain.
@MainActor
@Suite(.serialized, .globalState, .trackerIdentity(.simkl))
struct SimklImportLifecycleTests {
    @Test(arguments: [false, true])
    func `account or profile moving while Simkl history downloads discards the import`(changeAccount: Bool) async throws {
        let savedProfile = ActiveProfileStore.current
        let savedTokens = SimklTokenStore.load()
        defer {
            ActiveProfileStore.current = savedProfile
            if let savedTokens { SimklTokenStore.save(savedTokens) } else { SimklTokenStore.clear() }
            SimklPendingWatchedStore.clearAll()
        }
        await SimklImportURLProtocol.gate.prepare()
        let clientID = "simkl-import-\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimklImportURLProtocol.self, StubURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let client = SimklClient(session: transport, clientID: clientID, clientSecret: nil)
        func serveAccount(_ id: Int) {
            StubURLProtocol.register(host: "api.simkl.com", query: ("client_id", clientID), response: .init(body: "{\"user\":{\"name\":\"Account \(id)\"},\"account\":{\"id\":\(id)}}"))
        }
        serveAccount(1)
        #expect(SimklTokenStore.save(.init(accessToken: "fixture", refreshToken: "fixture", issuedAt: Date.now.timeIntervalSince1970, expiresIn: 604_800)))
        let defaultsName = "SimklImportLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let service = SimklService(client: client, outbox: TrackerMutationOutbox(defaults: defaults, storageKey: "outbox"))
        _ = await service.session.restore()
        #expect(service.isConnected)
        #expect(service.mutations.account == "simkl:1")
        let container = try makeTestContainer()
        let movie = Movie(id: "import-movie", streamId: 1, name: "Movie")
        movie.tmdbId = 100
        container.mainContext.insert(movie)
        try container.mainContext.save()
        let importTask = Task { await service.importWatched(into: container.mainContext) }
        await SimklImportURLProtocol.gate.started()
        #expect(service.isImporting)
        if changeAccount {
            serveAccount(2)
            _ = await service.session.restore()
            #expect(service.mutations.account == "simkl:2")
        } else {
            ActiveProfileStore.current = UUID()
        }
        await SimklImportURLProtocol.gate.release()
        await importTask.value
        #expect(!service.isImporting)
        #expect(service.lastImport == nil)
        #expect(!movie.isWatched)
        let checked = try #require(ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(!checked.isWatched)
        #expect(SimklPendingWatchedStore.load().isEmpty)
    }
}

private final nonisolated class SimklImportURLProtocol: URLProtocol {
    static let gate = SimklHistoryGate()
    private var responseTask: Task<Void, Never>?

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/sync/all-items") == true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        responseTask = Task {
            await Self.gate.wait()
            guard !Task.isCancelled, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"movies":[{"status":"completed","last_watched_at":"2026-10-03T12:00:00Z","movie":{"ids":{"tmdb":100}}}],"shows":[]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        responseTask?.cancel()
    }
}

private actor SimklHistoryGate {
    private var response: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func prepare() {
        hasStarted = false
    }

    func wait() async {
        hasStarted = true
        await withCheckedContinuation {
            response = $0
            observer?.resume()
            observer = nil
        }
    }

    func started() async {
        if !hasStarted { await withCheckedContinuation { observer = $0 } }
    }

    func release() {
        response?.resume()
        response = nil
    }
}
