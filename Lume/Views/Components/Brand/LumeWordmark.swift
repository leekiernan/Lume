//
//  LumeWordmark.swift
//  Lume
//
//  "lume" in Unbounded SemiBold — the wordmark and brand moments only; all
//  interface text stays the system font. The font ships in Resources/Fonts
//  (SIL Open Font License, alongside it) and is registered on first use, the
//  same way on every platform.
//

import CoreText
import OSLog
import SwiftUI

struct LumeWordmark: View {
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        Text(verbatim: "lume")
            .font(BrandFont.wordmark(size: size))
            // The board's letter-spacing: -0.03em.
            .kerning(-0.03 * size)
            .foregroundStyle(color)
            .accessibilityLabel(Text(verbatim: "Lume"))
    }
}

enum BrandFont {
    private static let postScriptName = "Unbounded-SemiBold"

    /// Registered once per process. A missing or rejected file falls back to
    /// a heavy rounded system font rather than failing the screen.
    private static let isRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: postScriptName, withExtension: "ttf") else {
            Logger.app.error("Wordmark font missing from the bundle")
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Already registered (e.g. a second scene) is fine.
        let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
        return code == CTFontManagerError.alreadyRegistered.rawValue
    }()

    static func wordmark(size: CGFloat) -> Font {
        isRegistered ? .custom(postScriptName, fixedSize: size) : .system(size: size, weight: .bold, design: .rounded)
    }
}
