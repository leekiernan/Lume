nonisolated enum SubtitleSearchPolicy {
    static func canSearch(isLive: Bool, isConfigured: Bool, supportsExternalSubtitles: Bool) -> Bool {
        !isLive && isConfigured && supportsExternalSubtitles
    }
}
