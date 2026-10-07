import Foundation

/// Scalar layout storage shared by hubs with stable section IDs.
nonisolated enum SectionTokens {
    static func decode(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func encode(_ ids: [String]) -> String {
        ids.joined(separator: "\n")
    }

    static func ordered(_ raw: String, available: [String]) -> [String] {
        let allowed = Set(available)
        var seen: Set<String> = []
        return (decode(raw) + available).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    static func toggling(_ id: String, in raw: String) -> String {
        var hidden = Set(decode(raw))
        if hidden.remove(id) == nil { hidden.insert(id) }
        return encode(hidden.sorted())
    }
}
