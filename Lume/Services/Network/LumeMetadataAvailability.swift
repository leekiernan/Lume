import Foundation

/// Compact `lume_meta` stamps advertise server-side data, not local completion.
/// Keep parsing lazy: bulk catalogues can contain hundreds of thousands of rows.
/// This DTO deliberately has no access to model freshness markers.
nonisolated struct LumeMetadataAvailability: Decodable, Equatable {
    enum Group: String { case tmdb, artwork, ratings }

    let version: Int
    private let tmdb: String?
    private let artwork: String?
    private let ratings: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case tmdb, artwork, ratings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        tmdb = try? container.decode(String.self, forKey: .tmdb)
        artwork = try? container.decode(String.self, forKey: .artwork)
        ratings = try? container.decode(String.self, forKey: .ratings)
    }

    /// A stamp is usable only with independently negotiated v1 capabilities.
    /// Invalid/future dates cannot make stale source data appear locally fresh.
    func availableAt(for group: Group, capabilities: LumeProxyCapabilities, now: Date = Date()) -> Date? {
        guard version == 1, capabilities.metadataBatchSize != nil else { return nil }
        let value: String? = switch group {
        case .tmdb: tmdb
        case .artwork: artwork
        case .ratings: ratings
        }
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: value), date <= now else { return nil }
        return date
    }
}
