import Foundation

nonisolated enum WebDAVPathIdentity {
    /// Preserve the parser/walker's existing identity: query-insensitive,
    /// percent-decoded, case-sensitive, and ignoring one trailing slash.
    static func key(_ absoluteString: String) -> String {
        let withoutQuery = absoluteString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? absoluteString
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }
}
