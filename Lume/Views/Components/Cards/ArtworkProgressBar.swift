//
//  ArtworkProgressBar.swift
//  Lume
//
//  The redesign's one progress treatment over artwork: a Lume pink bar flush
//  along the bottom edge of the poster, still or backdrop it measures, on a
//  dark track. The artwork's own clip shape rounds its corners.
//

import SwiftUI

struct ArtworkProgressBar: View {
    let fraction: Double

    #if os(tvOS)
        static let height: CGFloat = 6
    #else
        static let height: CGFloat = 4
    #endif

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.black.opacity(0.35))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.lumeAccent)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: Self.height)
        .frame(maxHeight: .infinity, alignment: .bottom)
        // The card's own label carries the progress (time left, episode).
        .accessibilityHidden(true)
    }
}
