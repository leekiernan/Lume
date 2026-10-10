import Foundation

nonisolated extension XtreamClient {
    /// Shared API construction, including the bulk digest requests. Authentication
    /// omits `action`; endpoint-specific parameters follow the credentials/action.
    static func playerAPIURL(
        for playlist: Playlist, action: String? = nil, parameters: [URLQueryItem] = []
    ) -> URL? {
        var items = credentials(for: playlist)
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        return endpointURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: items + parameters)
    }

    /// The guide is a standalone EPG source, not part of catalog fetching.
    static func xmltvURL(for playlist: Playlist) -> URL? {
        guard !playlist.serverURL.isEmpty else { return nil }
        return endpointURL(serverURL: playlist.serverURL, path: "xmltv.php", queryItems: credentials(for: playlist))
    }

    /// Optional Lume extensions use the same base path, account and provider
    /// query as Xtream, but are never inferred from an ordinary catalogue row.
    static func lumeCapabilitiesURL(for playlist: Playlist) -> URL? {
        guard !playlist.serverURL.isEmpty else { return nil }
        return endpointURL(serverURL: playlist.serverURL, path: "lume/v1/capabilities", queryItems: credentials(for: playlist))
    }

    private static func credentials(for playlist: Playlist) -> [URLQueryItem] {
        [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password)
        ]
    }

    private static func endpointURL(serverURL: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: serverURL)
        if !(components?.path.hasSuffix("/") ?? false), !path.hasPrefix("/") {
            components?.path.append("/")
        }
        components?.path.append(path)
        // Keep provider query items (including duplicates) ahead of ours. Do not
        // normalize paths or playback URLs as part of authenticated API assembly.
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + queryItems
        return components?.url
    }
}
