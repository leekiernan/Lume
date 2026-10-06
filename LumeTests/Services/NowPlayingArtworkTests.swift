import CoreGraphics
import Foundation
@testable import Lume
import Testing

struct NowPlayingArtworkTests {
    @Test func `only small square requests use compact artwork`() {
        for size in [CGSize(width: 64, height: 64), CGSize(width: 256, height: 256),
                     CGSize(width: 100, height: 96)]
        {
            #expect(NowPlayingArtwork.usesCompactCrop(for: size))
        }
        for size in [CGSize(width: 600, height: 600), CGSize(width: 200, height: 300),
                     CGSize(width: 160, height: 90), .zero,
                     CGSize(width: -1, height: -1), CGSize(width: CGFloat.infinity, height: 100),
                     CGSize(width: CGFloat.nan, height: 100)]
        {
            #expect(!NowPlayingArtwork.usesCompactCrop(for: size))
        }
    }

    @Test func `compact crops are square for portrait and episode still sources`() throws {
        for size in [CGSize(width: 200, height: 300), CGSize(width: 300, height: 200)] {
            let image = try makeImage(size: size)
            let crop = try #require(NowPlayingArtwork.centeredSquare(image))
            #expect(crop.width == 200)
            #expect(crop.height == 200)
            // The coloured centre survives; off-centre edges do not.
            let context = try #require(CGContext(data: nil, width: crop.width, height: crop.height,
                                                 bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            #expect(pixels[0] == 255)
            #expect(pixels[1] == 0)
            #expect(pixels[2] == 0)
        }
    }

    private func makeImage(size: CGSize) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let side = min(size.width, size.height)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side))
        return try #require(context.makeImage())
    }
}
