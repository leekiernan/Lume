import CoreGraphics
@testable import Lume
import SwiftUI
import Testing

@MainActor
struct EpisodeStillArtworkTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func `missing artwork uses the stable brand tile in either appearance`(_ scheme: ColorScheme) throws {
        let actual = try #require(ImageRenderer(content:
            EpisodeStillArtwork(title: "Sintel", url: nil, maxPixelSize: 80) {
                Text("E1")
            }
            .frame(width: 80, height: 45)
            .environment(\.colorScheme, scheme)).cgImage)
        let expected = try #require(ImageRenderer(content:
            Rectangle().fill(PosterTitleTile.color(for: "Sintel"))
                .frame(width: 80, height: 45)).cgImage)
        #expect(actual.width == 80 && actual.height == 45)
        #expect(try firstPixel(actual) == firstPixel(expected))
    }

    private func firstPixel(_ image: CGImage) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data) as Data
        return Array(data.prefix(image.bitsPerPixel / 8))
    }
}
