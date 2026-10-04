import CoreGraphics
import Foundation
import ImageIO
@testable import Lume
import Testing
import UniformTypeIdentifiers
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

@Suite(.serialized)
struct ImageDecoderTests {
    @Test func `decoder rejects non-image bytes`() {
        #expect(ImageDecoder.decode(Data("not an image".utf8), maxPixelSize: 200) == nil)
    }

    @Test func `decoder accepts a valid image at poster size`() throws {
        #expect(try ImageDecoder.decode(pngData(), maxPixelSize: 20) != nil)
    }

    @Test(arguments: [1.0, 2.0])
    func `detail budget produces HD or UHD decoded pixels from oversized bytes`(scale: Double) throws {
        let source = DetailArtworkSource(backdropURL: URL(string: "https://provider.test/backdrop.png"), posterFallbackURL: nil)
        let rendition = try #require(DetailArtworkPolicy.rendition(for: source, width: 1920, height: 900, displayScale: scale))
        let decoded = try #require(ImageDecoder.decode(pngData(width: 4096, height: 2304), maxPixelSize: rendition.decodeSizeInPoints * scale))
        #if canImport(UIKit)
            let cgImage = try #require(decoded.cgImage)
        #else
            let cgImage = try #require(decoded.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #endif
        #expect(cgImage.width == Int(rendition.decodeSizeInPixels))
        #expect(cgImage.height == Int(rendition.decodeSizeInPixels * 9 / 16))
    }

    @Test func `full decoded fallback is bounded without upscaling smaller sources`() throws {
        let source = try makeImage(width: 600, height: 900)
        let bounded = try #require(ImageDecoder.boundedImage(source, maxPixelSize: 300))
        #expect(bounded.width == 200 && bounded.height == 300)
        #expect(ImageDecoder.boundedImage(source, maxPixelSize: 1000) === source)
        #expect(ImageDecoder.boundedImage(source, maxPixelSize: nil) === source)
        for bad: CGFloat in [0, -1, .infinity, .nan] {
            #expect(ImageDecoder.boundedImage(source, maxPixelSize: bad) == nil)
            #expect(try ImageDecoder.decode(pngData(), maxPixelSize: bad) == nil)
        }
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
    }

    private func pngData(width: Int = 40, height: Int = 20) throws -> Data {
        let image = try makeImage(width: width, height: height)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
