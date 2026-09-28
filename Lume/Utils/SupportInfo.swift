//
//  SupportInfo.swift
//  Lume
//
//  Canonical support / contact links, shared by the iOS Settings list (tappable
//  Link rows) and the tvOS About pane (read-only text plus a scannable QR code,
//  since Apple TV can't open a URL itself). One source of truth so the two
//  surfaces can never drift.
//

import Foundation

nonisolated enum SupportInfo {
    static let website = "https://getlume.org"
    static let email = "support@getlume.org"
    /// Where diagnostic reports go — this fork's own inbox, so logs from these
    /// builds reach the people who can act on them. Support, website and
    /// Discord stay upstream's.
    static let diagnosticsEmail = "lume@starlord.co"
    static let discord = "https://discord.gg/DMnQfr69Ug"

    /// The App Store deep link that opens straight to the write-a-review
    /// composer (`?action=write-review`).
    static let appStoreReview = "https://apps.apple.com/app/id6779551584?action=write-review"

    /// Scheme-stripped forms for compact on-screen display.
    static let websiteDisplay = "GetLume.org"
    static let discordDisplay = "discord.gg/DMnQfr69Ug"

    static var websiteURL: URL? {
        URL(string: website)
    }

    static var discordURL: URL? {
        URL(string: discord)
    }

    static var emailURL: URL? {
        URL(string: "mailto:\(email)")
    }

    static var diagnosticsEmailURL: URL? {
        URL(string: "mailto:\(diagnosticsEmail)")
    }

    static var appStoreReviewURL: URL? {
        URL(string: appStoreReview)
    }

    /// Marketing version (`CFBundleShortVersionString`, e.g. "2.1.0"), sourced
    /// from the build's `MARKETING_VERSION` rather than a hardcoded string so
    /// the iOS and tvOS About panes always reflect the shipped version.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
