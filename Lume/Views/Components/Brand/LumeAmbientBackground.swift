//
//  LumeAmbientBackground.swift
//  Lume
//
//  The ambient ground: Night with a violet glow from the top trailing corner
//  and a faint pink one from the bottom leading corner. Behind plain screens,
//  and behind hero art while it loads.
//

import SwiftUI

struct LumeAmbientBackground: View {
    /// The brand ground (launch, splash) glows from the centre instead.
    var style: Style = .screen

    enum Style {
        case screen
        case brand
        /// Behind a detail hero's backdrop while it loads.
        case backdrop
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // The board's ellipses are sized for a 1920-point-wide screen.
            let unit = max(size.width, 1) / 1920
            ZStack {
                ground
                switch style {
                case .screen:
                    glow(Color.lumeViolet.opacity(0.38), width: 1200, height: 700, unit: unit)
                        .position(x: size.width * 0.85, y: -size.height * 0.1)
                    glow(Color.lumeAccent.opacity(0.10), width: 900, height: 600, unit: unit)
                        .position(x: 0, y: size.height)
                case .brand:
                    glow(Color.lumeViolet.opacity(0.5), width: 760, height: 540, unit: unit)
                        .position(x: size.width * 0.5, y: size.height * 0.44)
                    glow(Color.lumeAccent.opacity(0.12), width: 900, height: 600, unit: unit)
                        .position(x: size.width * 0.12, y: size.height)
                case .backdrop:
                    glow(Color.lumeViolet.opacity(0.5), width: 1000, height: 700, unit: unit)
                        .position(x: size.width * 0.5, y: size.height * 0.3)
                    glow(Color.lumeAccent.opacity(0.16), width: 700, height: 500, unit: unit)
                        .position(x: size.width * 0.14, y: size.height * 0.2)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var ground: Color {
        style == .screen ? .lumeNight : .lumeInk
    }

    /// A CSS `radial-gradient(w h at …, colour, transparent 70%)`: an
    /// elliptical falloff reaching clear at 70% of its radii.
    private func glow(_ color: Color, width: CGFloat, height: CGFloat, unit: CGFloat) -> some View {
        RadialGradient(colors: [color, color.opacity(0)], center: .center,
                       startRadius: 0, endRadius: width * unit * 0.7)
            .frame(width: width * unit * 2, height: width * unit * 2)
            .scaleEffect(x: 1, y: height / width)
    }
}
