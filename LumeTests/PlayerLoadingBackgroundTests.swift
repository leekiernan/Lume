import CoreGraphics
@testable import Lume
import SwiftUI
import Testing

@MainActor
struct PlayerLoadingBackgroundTests {
    @Test func `opening uses the opaque existing brand ground`() throws {
        let actual = try render(PlayerLoadingBackground(isOpening: true))
        let expected = try render(LumeAmbientBackground(style: .brand))
        #expect(actual.width == expected.width && actual.height == expected.height)
        #expect(try firstPixel(actual) == firstPixel(expected))
        #expect(actual.alphaInfo == expected.alphaInfo)
    }

    @Test func `buffering retains the translucent dimmer over video`() throws {
        let actual = try render(PlayerLoadingBackground(isOpening: false))
        let expected = try render(Color.black.opacity(0.4))
        #expect(try firstPixel(actual) == firstPixel(expected))
        let opening = try render(PlayerLoadingBackground(isOpening: true))
        #expect(try firstPixel(actual) != firstPixel(opening))
    }

    private func render(_ view: some View) throws -> CGImage {
        try #require(ImageRenderer(content: view
                .frame(width: 192, height: 108)
                .environment(\.colorScheme, .dark)).cgImage)
    }

    private func firstPixel(_ image: CGImage) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data) as Data
        return Array(data.prefix(image.bitsPerPixel / 8))
    }
}
