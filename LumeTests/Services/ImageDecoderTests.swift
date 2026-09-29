import CoreGraphics
import Foundation
import ImageIO
@testable import Lume
import Testing
import UniformTypeIdentifiers

struct ImageDecoderTests {
    @Test func `decoder rejects non-image bytes`() {
        #expect(ImageDecoder.decode(Data("not an image".utf8), maxPixelSize: 200) == nil)
    }

    @Test func `decoder accepts a valid image at poster size`() throws {
        #expect(try ImageDecoder.decode(pngData(), maxPixelSize: 20) != nil)
    }

    private func pngData() throws -> Data {
        let image = try #require(CGContext(
            data: nil,
            width: 40,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 40 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
