//
//  LumeTheme.swift
//  Lume
//
//  The app's own colour, taken from the logo's gradient (pink #FF8BD7 to
//  purple #7000B4) and tuned for legibility:
//
//  - Light: #8A1FC4 — 6.8:1 as text on white, 6.8:1 under a white label.
//  - Dark:  #B65CF0 — 5.8:1 as text on black, 4.7:1 on a raised dark
//    surface, 3.6:1 under a white label (bold button text).
//
//  The pair lives in `AccentColor`, so every system control on iOS — buttons,
//  toggles, links, progress — picks it up with no code. `Color.accentColor`
//  is not the brand everywhere, though: tvOS renders it white, and macOS
//  replaces it with the viewer's own system accent (rightly, for controls).
//  Anything meant to read as "the app's colour" uses `Color.lumeAccent`.
//

import SwiftUI

extension Color {
    /// The brand accent, on every platform.
    static var lumeAccent: Color {
        #if os(tvOS)
            // Lume's tvOS screens are always dark, but the TV itself may be
            // set to a light appearance, which would pick the asset's light
            // variant — so the dark value is fixed here.
            Color(red: 0xB6 / 255, green: 0x5C / 255, blue: 0xF0 / 255)
        #else
            // The asset by name: `Color.accentColor` on macOS is the viewer's
            // system accent, not this.
            Color("AccentColor")
        #endif
    }
}

extension ShapeStyle where Self == Color {
    /// `Color.lumeAccent`, where a `ShapeStyle` is expected.
    static var lumeAccent: Color {
        Color.lumeAccent
    }
}
