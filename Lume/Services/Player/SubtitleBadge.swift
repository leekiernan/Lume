import Foundation

/// Shared result-row semantics, independent of either platform layout.
nonisolated struct SubtitleBadge: Identifiable {
    let id: String
    let systemImage: String
}

nonisolated extension OnlineSubtitle {
    var badges: [SubtitleBadge] {
        var badges: [SubtitleBadge] = []
        if isHearingImpaired { badges.append(SubtitleBadge(id: "cc", systemImage: "captions.bubble")) }
        if isFromTrusted { badges.append(SubtitleBadge(id: "trusted", systemImage: "checkmark.seal")) }
        if isMachineTranslated { badges.append(SubtitleBadge(id: "machine", systemImage: "wand.and.stars")) }
        return badges
    }
}
