import CryptoKit
import Foundation
import OSLog
import SwiftData

/// Availability only. Even a supported metadata endpoint cannot certify that
/// a title's details/artwork/ratings have been applied to the local catalogue.
nonisolated struct LumeProxyCapabilities: Decodable, Equatable {
    let version: Int
    let metadata: LumeProxyMetadataCapability?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        // A malformed/unknown optional feature must not enable that route or
        // break unrelated features of an otherwise recognised envelope.
        metadata = try? container.decode(LumeProxyMetadataCapability.self, forKey: .metadata)
    }

    var metadataBatchSize: Int? {
        guard version == 1, let metadata, metadata.version == 1, metadata.maxBatchSize > 0 else { return nil }
        return min(metadata.maxBatchSize, 50)
    }
}

nonisolated struct LumeProxyMetadataCapability: Decodable, Equatable {
    let version: Int
    let maxBatchSize: Int
    let languages: [String]?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case maxBatchSize = "max_batch_size"
        case languages
    }
}

/// A value snapshot: no managed Playlist crosses a capability request's await.
/// The hash scopes the account/path/query without storing secrets in cache keys.
nonisolated struct LumeProxySource: Hashable {
    let playlistID: UUID
    let capabilitiesURL: URL
    let identity: String

    init?(playlist: Playlist) {
        guard playlist.sourceType == .xtream, let url = XtreamClient.lumeCapabilitiesURL(for: playlist),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        playlistID = playlist.id
        capabilitiesURL = url
        identity = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func snapshot(contentID: String, in context: ModelContext) -> Self? {
        guard let playlist = PlaylistOwner.playlist(forPrefixedID: contentID, in: context) else { return nil }
        return Self(playlist: playlist)
    }

    func metadataURL(type: LumeMetadataKind, ids: [Int], language: String) -> URL? {
        guard var components = URLComponents(url: capabilitiesURL, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasSuffix("/capabilities") else { return nil }
        components.percentEncodedPath.removeLast("capabilities".count)
        components.percentEncodedPath += "metadata"
        let existing = components.queryItems ?? []
        components.queryItems = existing + [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "language", value: language)
        ]
        return components.url
    }
}

/// Small, process-local negotiation cache shared by sync and future metadata
/// readers. A capability never substitutes for a complete metadata payload.
actor LumeProxyCapabilityStore {
    static let shared = LumeProxyCapabilityStore()

    enum State: Equatable {
        case supported(LumeProxyCapabilities)
        case unsupported
        case unavailable

        var cacheLifetime: TimeInterval {
            switch self {
            case .supported: 3600
            case .unsupported: 6 * 3600
            case .unavailable: 60
            }
        }
    }

    private struct Entry {
        let identity: String
        let state: State
        let expiresAt: Date
    }

    private struct Flight {
        let id = UUID()
        let task: Task<State, Never>
    }

    private let session: URLSession
    private var entries: [UUID: Entry] = [:]
    private var inFlight: [String: Flight] = [:]
    private var currentIdentity: [UUID: String] = [:]

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    /// Reuses a fresh result, coalesces concurrent callers, and bounds a failed
    /// optional probe. Full sync can bypass the cache, but never an in-flight
    /// request. Unavailability is short-lived and never authorises metadata.
    func capabilities(for source: LumeProxySource, refresh: Bool = false, now: Date = Date()) async throws -> State {
        try Task.checkCancellation()
        currentIdentity[source.playlistID] = source.identity
        if let entry = entries[source.playlistID], entry.identity != source.identity {
            entries.removeValue(forKey: source.playlistID)
        }
        if !refresh, let entry = entries[source.playlistID], now < entry.expiresAt {
            return entry.state
        }

        let key = source.playlistID.uuidString + source.identity
        let flight: Flight
        if let existing = inFlight[key] {
            flight = existing
        } else {
            let session = session
            flight = Flight(task: Task { await Self.fetch(source.capabilitiesURL, session: session) })
            inFlight[key] = flight
        }
        let state = await flight.task.value
        if inFlight[key]?.id == flight.id {
            inFlight.removeValue(forKey: key)
        }
        // An old request finishing after an account edit cannot overwrite the
        // new account's cached capabilities. Cancellation never certifies data.
        try Task.checkCancellation()
        if currentIdentity[source.playlistID] == source.identity {
            entries[source.playlistID] = Entry(identity: source.identity, state: state, expiresAt: now.addingTimeInterval(state.cacheLifetime))
        }
        return state
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }

    private static func fetch(_ url: URL, session: URLSession) async -> State {
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .unavailable }
            if response.statusCode == 404 {
                Logger.network.info("Proxy capabilities: unsupported")
                return .unsupported
            }
            guard response.statusCode == 200, data.count <= 65536,
                  let capabilities = try? JSONDecoder().decode(LumeProxyCapabilities.self, from: data) else { return .unavailable }
            guard capabilities.version == 1 else { return .unsupported }
            let batchSize = capabilities.metadataBatchSize ?? 0
            Logger.network.info("Proxy capabilities: v1; metadata batch limit=\(batchSize, privacy: .public)")
            return .supported(capabilities)
        } catch {
            // Do not log URLs/errors: optional API errors can contain credentials.
            return .unavailable
        }
    }
}
