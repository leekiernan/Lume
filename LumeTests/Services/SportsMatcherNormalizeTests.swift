//
//  SportsMatcherNormalizeTests.swift
//  LumeTests
//
//  `SportsMatcher.normalize` was rewritten as one pass for speed (upstream
//  8839ce8): the channel resolver runs it three times per guide listing. The
//  rewrite must produce exactly what the original did.
//

import Foundation
@testable import Lume
import Testing

struct SportsMatcherNormalizeTests {
    /// The implementation `SportsMatcher.normalize` replaced, kept as the
    /// reference its one-pass rewrite must agree with.
    private func referenceNormalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return " \(String(cleaned).split(separator: " ").joined(separator: " ")) "
    }

    @Test(arguments: [
        "", " ", "Bayern", "FC Bayern München – Borussia Dortmund", "  Live:  F1 / Qualifying!! ",
        "1. Freies Training", "Atlético de Madrid", "Sky Sport 1 HD (DE)", "ÀÉÎÕÜ çñ", "a|b|c", "123-456",
        "東京 ヴェルディ vs 横浜", "e\u{301}quipe", "Ελλάδα – Κύπρος", "ﬁnal"
    ])
    func `normalize matches the reference implementation`(text: String) {
        #expect(SportsMatcher.normalize(text) == referenceNormalize(text))
    }

    /// The one place the two differ, on purpose: an emoji's variation selector
    /// (U+FE0F) counts as alphanumeric. The reference built `Character`s, so
    /// the selector fused with the space before it into one grapheme `split`
    /// could not break — a stray double space. The rewrite emits it as its own
    /// word. Either way the team names stay whole words, which is what matching
    /// reads.
    @Test func `emoji in a channel or guide name leave the team words matchable`() {
        let text = "⚽️ Arsenal 🆚 Chelsea"
        for normalized in [SportsMatcher.normalize(text), referenceNormalize(text)] {
            #expect(normalized.contains(" arsenal "))
            #expect(normalized.contains(" chelsea "))
        }
    }
}
