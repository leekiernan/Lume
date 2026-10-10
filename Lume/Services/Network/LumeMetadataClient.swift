import Foundation
import OSLog

/// Optional read-only delivery. Unsupported providers keep today's path; a
/// whole-service outage is cooled down across batches so it cannot fan out.
actor LumeMetadataClient {
    static let shared = LumeMetadataClient()
    static let background = LumeMetadataClient(background: true)

    enum Result {
        case available([Int: TMDBTitleDetails], statuses: [Int: LumeMetadataItemStatus])
        case unsupported
        case unavailable
    }

    private struct Cached {
        let data: Data
        let etag: String?
        let fetchedAt: Date
        let reuseDuration: TimeInterval
    }

    private struct Failure {
        let until: Date
        let result: Result
    }

    private struct Flight {
        let id = UUID()
        let task: Task<Result, Error>
    }

    private struct Read {
        let source: LumeProxySource
        let type: LumeMetadataKind
        let ids: [Int]
        let language: String
        let capabilities: LumeProxyCapabilities
        let now: Date

        var url: URL? {
            source.metadataURL(type: type, ids: ids, language: language)
        }
    }

    private let session: URLSession
    private let capabilities: LumeProxyCapabilityStore
    private var cache: [URL: Cached] = [:]
    private var order: [URL] = []
    private var failures: [String: Failure] = [:]
    private var inFlight: [URL: Flight] = [:]

    init(session: URLSession? = nil, capabilities: LumeProxyCapabilityStore = .shared, background: Bool = false) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        if background {
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
        }
        self.session = session ?? URLSession(configuration: configuration)
        self.capabilities = capabilities
    }

    /// IDs are TMDB IDs, not Xtream stream/series IDs. Batches are canonical,
    /// bounded by both the advertised limit and 50. Returned values carry proof
    /// only after complete payload validation, never from an ETag alone.
    func fetch(source: LumeProxySource, type: LumeMetadataKind, ids: [Int], language: String, now: Date = Date()) async throws -> Result {
        try Task.checkCancellation()
        failures = failures.filter { now < $0.value.until }
        if failures.count > 64 { failures.removeAll() }
        let identity = source.identity + type.rawValue + language
        if let failure = failures[identity], now < failure.until { return failure.result }
        switch try await capabilities.capabilities(for: source) {
        case .unsupported: return .unsupported
        case .unavailable: return .unavailable
        case let .supported(capability):
            guard let limit = capability.metadataBatchSize,
                  capability.metadata?.languages?.contains(language) != false else { return .unsupported }
            let sortedIDs = Set(ids.filter { $0 > 0 }).sorted()
            guard sortedIDs.count <= 50 else { throw LumeMetadataError.incomplete }
            var values: [Int: TMDBTitleDetails] = [:]
            var statuses: [Int: LumeMetadataItemStatus] = [:]
            for offset in stride(from: 0, to: sortedIDs.count, by: limit) {
                let chunk = Array(sortedIDs[offset ..< min(offset + limit, sortedIDs.count)])
                let read = Read(source: source, type: type, ids: chunk, language: language, capabilities: capability, now: now)
                let result = try await coalescedBatch(read)
                try Task.checkCancellation()
                switch result {
                case let .available(details, states):
                    values.merge(details) { _, new in new }
                    statuses.merge(states) { _, new in new }
                case .unsupported, .unavailable:
                    failures[identity] = Failure(until: now.addingTimeInterval(result.isUnsupported ? 6 * 3600 : 60), result: result)
                    return result
                }
            }
            return .available(values, statuses: statuses)
        }
    }

    private func coalescedBatch(_ read: Read) async throws -> Result {
        guard let url = read.url else { return .unsupported }
        let flight: Flight
        if let existing = inFlight[url] {
            flight = existing
        } else {
            flight = Flight(task: Task {
                try await self.batch(read)
            })
            inFlight[url] = flight
        }
        defer {
            if inFlight[url]?.id == flight.id { inFlight.removeValue(forKey: url) }
        }
        let result = try await flight.task.value
        try Task.checkCancellation()
        return result
    }

    private func batch(_ read: Read) async throws -> Result {
        guard let url = read.url else { return .unsupported }
        let now = read.now
        let cached = cache[url]
        if let cached, now >= cached.fetchedAt, now.timeIntervalSince(cached.fetchedAt) < cached.reuseDuration {
            return decode(cached.data, read: read)
        }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            var (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 304, cached == nil {
                // One unconditional recovery; a 304 without retained bytes is
                // not a successful read and must never establish local proof.
                request.setValue(nil, forHTTPHeaderField: "If-None-Match")
                (data, response) = try await session.data(for: request)
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { return .unavailable }
            if response.statusCode == 404 { return .unsupported }
            if response.statusCode == 304, let cached { data = cached.data }
            guard response.statusCode == 200 || (response.statusCode == 304 && cached != nil),
                  !data.isEmpty, data.count <= 8 * 1024 * 1024 else { return .unavailable }
            let result = decode(data, read: read)
            if case let .available(items, statuses) = result {
                let etag = response.value(forHTTPHeaderField: "ETag") ?? (response.statusCode == 304 ? cached?.etag : nil)
                // Keep retained bytes/ETags, but don't hide newly ready data
                // behind the five-minute complete-response cache.
                let reuseDuration: TimeInterval = statuses.values.contains(.pending) ? 10
                    : (items.count + statuses.values.count(where: { $0 == .notFound }) < read.ids.count ? 60 : 300)
                retain(Cached(data: data, etag: etag, fetchedAt: now, reuseDuration: reuseDuration), for: url)
                let kind = read.type.rawValue
                let requested = read.ids.count
                let pending = statuses.values.count(where: { $0 == .pending })
                Logger.network.info("Proxy metadata [\(kind, privacy: .public)]: \(items.count) of \(requested) complete, \(pending) pending; HTTP \(response.statusCode)")
            }
            return result
        } catch {
            try Task.checkCancellation()
            // Optional failures must not log authenticated URLs or secrets.
            return .unavailable
        }
    }

    private func decode(_ data: Data, read: Read) -> Result {
        guard let batch = try? JSONDecoder().decode(LumeMetadataBatch.self, from: data),
              batch.version == 1, batch.type == read.type, batch.language == read.language else { return .unavailable }
        let requestedIDs = Set(read.ids)
        return .available(batch.details(source: read.source, requestedIDs: requestedIDs, capabilities: read.capabilities, now: read.now),
                          statuses: batch.statuses(requestedIDs: requestedIDs))
    }

    private func retain(_ value: Cached, for url: URL) {
        order.removeAll { $0 == url }
        cache[url] = value
        order.append(url)
        while order.count > 32 || cache.values.reduce(0, { $0 + $1.data.count }) > 16 * 1024 * 1024 {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}

private nonisolated extension LumeMetadataClient.Result {
    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}
