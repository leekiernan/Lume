//
//  XtreamClient+Digest.swift
//  Lume
//
//  Fetches of the three bulk catalog endpoints that skip the decode when the
//  response is byte-identical to the one last imported.
//
//  Panels/proxies with ETags can also skip the download. Other providers keep
//  the digest path: a real 280k-row provider spent about 18 s on a Mac decoding,
//  comparing and sweeping a catalog that had not changed.
//

import CryptoKit
import Foundation

/// A bulk fetch that may have found the payload unchanged.
nonisolated enum XtreamFetch<Value: Sendable> {
    /// The response matched a committed digest or its request-scoped ETag.
    case unchanged(validator: XtreamDigestStore.Validator? = nil)
    /// A new payload, with the SHA-256 digest of its bytes.
    case fetched(Value, digest: String, validator: XtreamDigestStore.Validator? = nil)

    func map<Mapped: Sendable>(_ transform: (Value) -> Mapped) -> XtreamFetch<Mapped> {
        switch self {
        case let .unchanged(validator): .unchanged(validator: validator)
        case let .fetched(value, digest, validator): .fetched(transform(value), digest: digest, validator: validator)
        }
    }
}

extension XtreamClient {
    func getVODStreamsIfChanged(playlist: Playlist, knownDigest: String?, knownValidator: XtreamDigestStore.Validator? = nil) async throws -> XtreamFetch<[XtreamVODStream]> {
        let fetch: XtreamFetch<XtreamList<XtreamVODStream>> = try await fetchIfChanged(
            action: "get_vod_streams", playlist: playlist, knownDigest: knownDigest, knownValidator: knownValidator,
            phases: RequestPhases(fetch: .xtreamFetchMovies, decode: .xtreamDecodeMovies)
        )
        return fetch.map(\.items)
    }

    func getSeriesIfChanged(playlist: Playlist, knownDigest: String?, knownValidator: XtreamDigestStore.Validator? = nil) async throws -> XtreamFetch<[XtreamSeries]> {
        let fetch: XtreamFetch<XtreamList<XtreamSeries>> = try await fetchIfChanged(
            action: "get_series", playlist: playlist, knownDigest: knownDigest, knownValidator: knownValidator,
            phases: RequestPhases(fetch: .xtreamFetchSeries, decode: .xtreamDecodeSeries)
        )
        return fetch.map(\.items)
    }

    func getLiveStreamsIfChanged(playlist: Playlist, knownDigest: String?, knownValidator: XtreamDigestStore.Validator? = nil) async throws -> XtreamFetch<[XtreamLiveStream]> {
        let fetch: XtreamFetch<XtreamList<XtreamLiveStream>> = try await fetchIfChanged(
            action: "get_live_streams", playlist: playlist, knownDigest: knownDigest, knownValidator: knownValidator,
            phases: RequestPhases(fetch: .xtreamFetchLiveStreams, decode: .xtreamDecodeLiveStreams)
        )
        return fetch.map(\.items)
    }

    private func fetchIfChanged<T: Decodable & Sendable>(
        action: String,
        playlist: Playlist,
        knownDigest: String?,
        knownValidator: XtreamDigestStore.Validator?,
        phases: RequestPhases
    ) async throws -> XtreamFetch<T> {
        guard let url = Self.playerAPIURL(for: playlist, action: action) else {
            throw XtreamError.invalidURL
        }
        let identity = await Self.sha256Hex(of: Data(url.absoluteString.utf8))
        let knownValidator = knownDigest != nil && knownValidator?.requestIdentity == identity ? knownValidator : nil
        return try await withRetries(action: action) {
            // HTTP caching must not supply a validator for a download that was
            // never committed, or hide a full-sync request behind a cached 200.
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue(knownValidator?.etag, forHTTPHeaderField: "If-None-Match")
            var (data, response) = try await fetchValidated(request, action: action, phases: phases, allowNotModified: true)
            if (response as? HTTPURLResponse)?.statusCode == 304 {
                if let knownValidator {
                    return .unchanged(validator: Self.validator(from: response, identity: identity) ?? knownValidator)
                }
                // A stray 304 cannot certify an absent or untrusted catalogue.
                request.setValue(nil, forHTTPHeaderField: "If-None-Match")
                (data, response) = try await fetchValidated(request, action: action, phases: phases)
            }
            let validator = Self.validator(from: response, identity: identity)
            let digest = await Self.sha256Hex(of: data)
            if digest == knownDigest { return .unchanged(validator: validator) }
            let value = try await decodeResponse(T.self, data: data, response: response, action: action, phases: phases)
            return .fetched(value, digest: digest, validator: validator)
        }
    }

    private static func validator(from response: URLResponse, identity: String) -> XtreamDigestStore.Validator? {
        guard let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
              !etag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return XtreamDigestStore.Validator(etag: etag, requestIdentity: identity)
    }

    /// Off every actor, like the decode it can replace: about 0.1 s for a
    /// 66 MB payload.
    @concurrent
    static func sha256Hex(of data: Data) async -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
