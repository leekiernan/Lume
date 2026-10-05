import Foundation

nonisolated enum MediaServerURL {
    /// Preserve the existing one-trailing-slash normalization used by both
    /// clients. This does not strip queries/fragments or validate a source URL.
    static func normalized(_ url: URL) -> URL {
        let string = url.absoluteString
        guard string.hasSuffix("/"), string.count > 1 else { return url }
        return URL(string: String(string.dropLast())) ?? url
    }
}
