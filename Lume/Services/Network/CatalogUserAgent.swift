//
//  CatalogUserAgent.swift
//  Lume
//
//  The User-Agent every catalog client sends.
//

import Foundation

/// A recognized media-player User-Agent for catalog requests.
///
/// Many Xtream/IPTV panels gate `player_api.php` (and m3u playlist exports)
/// behind a User-Agent allowlist: for an unrecognized UA — such as the default
/// `Lume/… CFNetwork/… Darwin/…` — they return an HTML block/portal page or an
/// empty body instead of JSON. That decodes as `DecodingError.dataCorrupted`,
/// surfaced to the user as "the data couldn't be read because it isn't in the
/// correct format". Sending a VLC UA, which panels universally accept, makes
/// them respond with the expected JSON. (Other native players, e.g. UHF, work
/// against these same panels for exactly this reason.)
nonisolated let lumeCatalogUserAgent = "VLC/3.0.20 LibVLC/3.0.20"
