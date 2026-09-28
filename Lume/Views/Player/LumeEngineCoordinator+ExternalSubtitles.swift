//
//  LumeEngineCoordinator+ExternalSubtitles.swift
//  Lume
//
//  A subtitle file found through the OpenSubtitles search, loaded into the
//  engine's sidecar lane. Split from LumeEngineCoordinator.swift to keep it
//  within the size limit.
//

import Foundation
import LumeEngine
import OSLog

extension LumeEngineCoordinator: ExternalSubtitleLoading {
    /// Id for the sidecar track in the overlay's subtitle menu. Prefixed so it
    /// can never collide with an embedded track's stream index.
    static var externalTrackID: String {
        "external"
    }

    func loadExternalSubtitle(_ subtitle: ExternalSubtitle) {
        externalSubtitle = subtitle
        selectedSubtitleID = Self.externalTrackID
        loadExternalSubtitleFile(subtitle)
    }

    /// Hands the file to the engine, which parses it in full and replaces
    /// whatever subtitle lane was active. On failure the track is dropped from
    /// the menu rather than left selected but silent.
    func loadExternalSubtitleFile(_ subtitle: ExternalSubtitle) {
        subtitleCues.update(nil)
        if let info = mediaInfo {
            publishTracks(info: info)
        }
        let session = session
        Task {
            do {
                try await session?.loadExternalSubtitles(url: subtitle.fileURL.absoluteString)
            } catch {
                Logger.player.error("LumeEngine could not load external subtitles: \(LogRedaction.describe(error), privacy: .public)")
                self.externalSubtitle = nil
                self.selectedSubtitleID = nil
                if let info = self.mediaInfo {
                    self.publishTracks(info: info)
                }
            }
        }
    }
}
