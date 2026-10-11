import Foundation

nonisolated extension TraktClient {
    /// Start resumes a paused session; stop settles completed playback into
    /// watched history according to Trakt's completion threshold. Discard ends
    /// an abandoned session without retaining a manufactured resume point.
    @discardableResult
    func scrobble(
        _ target: TraktScrobbleTarget,
        action: TraktScrobbleAction,
        progress: Double,
        accessToken: String
    ) async throws -> TraktScrobbleResponse {
        if action == .discard {
            // Trakt rejects stops below 1%. Settle at its minimum, then remove
            // that exact paused entry. Never delete a completed history entry.
            let stopped = try await scrobble(target, action: .stop, progress: 1, accessToken: accessToken)
            guard stopped.action == "pause", let id = stopped.id, id > 0 else { throw TraktError.invalidResponse }
            do {
                try await removePlayback(id: id, accessToken: accessToken)
            } catch TraktError.server(404) {
                // Already removed, for example by another connected device.
            }
            return TraktScrobbleResponse(id: nil, action: "discard", progress: 0)
        }
        return try await post(
            "/scrobble/\(action.rawValue)",
            body: TraktScrobbleRequest(target: target, progress: progress),
            accessToken: accessToken
        )
    }
}
