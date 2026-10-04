import Foundation
@testable import Lume
import Testing

struct DetailArtworkPolicyTests {
    private let backdrop = URL(string: "https://image.tmdb.org/t/p/w1280/backdrop.jpg?test=1")!
    private let poster = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg?test=1")!

    @Test func `source preference and poster composition do not depend on request outcomes`() {
        let preferred = DetailArtworkSource(backdropURL: backdrop, posterFallbackURL: poster)
        #expect(preferred.url == backdrop)
        #expect(preferred.sourceRatio == HeroArtworkPolicy.landscapeRatio)
        let fallback = DetailArtworkSource(backdropURL: nil, posterFallbackURL: poster)
        #expect(fallback.url == poster)
        #expect(fallback.sourceRatio == HeroArtworkPolicy.portraitRatio)
        #expect(DetailArtworkSource(backdropURL: nil, posterFallbackURL: nil).url == nil)
    }

    @Test func `HD and UHD detail backdrops retain output resolution with separate cache identities`() throws {
        let source = DetailArtworkSource(backdropURL: backdrop, posterFallbackURL: nil)
        let highDefinition = try #require(DetailArtworkPolicy.rendition(for: source, width: 1920, height: 900, displayScale: 1))
        let uhd = try #require(DetailArtworkPolicy.rendition(for: source, width: 1920, height: 900, displayScale: 2))
        #expect(highDefinition.decodeSizeInPixels == 1920)
        #expect(uhd.decodeSizeInPixels == 3840)
        #expect(highDefinition.url?.path == "/t/p/original/backdrop.jpg")
        #expect(uhd.url?.query == "test=1")
        let url = try #require(uhd.url)
        #expect(ImagePipeline.memoryKey(url, maxPixelSize: highDefinition.decodeSizeInPixels) != ImagePipeline.memoryKey(url, maxPixelSize: uhd.decodeSizeInPixels))
        #expect(ImagePipeline.memoryKey(url, maxPixelSize: uhd.decodeSizeInPoints * 2) == ImagePipeline.memoryKey(url, maxPixelSize: uhd.decodeSizeInPixels))
    }

    @Test func `fill crop and display scale determine the bounded rendition`() throws {
        let source = DetailArtworkSource(backdropURL: backdrop, posterFallbackURL: nil)
        let cropped = try #require(DetailArtworkPolicy.rendition(for: source, width: 390, height: 500, displayScale: 3))
        // 500pt × 16:9 × 3 ≈ 2667px, rounded up to the next ladder width.
        #expect(cropped.decodeSizeInPixels == 3840)
        #expect(abs(cropped.decodeSizeInPoints * 3 - cropped.decodeSizeInPixels) < 0.001)
        let small = try #require(DetailArtworkPolicy.rendition(for: source, width: 600, height: 300, displayScale: 1))
        #expect(small.url?.path == "/t/p/w780/backdrop.jpg")
        let large = try #require(DetailArtworkPolicy.rendition(for: source, width: 6000, height: 4000, displayScale: 3))
        #expect(large.decodeSizeInPixels == DetailArtworkPolicy.maximumPixelEdge)
        #expect(large.decodeSizeInPoints * 3 == DetailArtworkPolicy.maximumPixelEdge)
    }

    @Test func `small resizes keep the same rendition and cache key`() throws {
        let source = DetailArtworkSource(backdropURL: backdrop, posterFallbackURL: nil)
        let renditions = try [1100, 1150, 1199, 1280].map { width in
            try #require(DetailArtworkPolicy.rendition(for: source, width: CGFloat(width), height: 500, displayScale: 1))
        }
        #expect(Set(renditions.map(\.decodeSizeInPixels)) == [1280])
        #expect(Set(renditions.map(\.url)).count == 1)
        let wider = try #require(DetailArtworkPolicy.rendition(for: source, width: 1300, height: 500, displayScale: 1))
        #expect(wider.decodeSizeInPixels == 1920)
    }

    @Test func `poster fallback uses poster tiers and bounds large portrait crops`() throws {
        let source = DetailArtworkSource(backdropURL: nil, posterFallbackURL: poster)
        let small = try #require(DetailArtworkPolicy.rendition(for: source, width: 300, height: 200, displayScale: 1))
        #expect(small.decodeSizeInPixels == 480)
        #expect(small.url?.path == "/t/p/w342/poster.jpg")
        let wide = try #require(DetailArtworkPolicy.rendition(for: source, width: 1920, height: 900, displayScale: 2))
        #expect(wide.decodeSizeInPixels == DetailArtworkPolicy.maximumPixelEdge)
        #expect(wide.url?.path == "/t/p/original/poster.jpg")
        #expect(wide.url?.query == "test=1")
    }

    @Test func `provider URL spelling credentials and query are not rewritten`() throws {
        let provider = try #require(URL(string: "https://provider.test/images/cover.jpg?token=keep"))
        for source in [DetailArtworkSource(backdropURL: provider, posterFallbackURL: poster), DetailArtworkSource(backdropURL: nil, posterFallbackURL: provider)] {
            #expect(DetailArtworkPolicy.rendition(for: source, width: 1920, height: 900, displayScale: 2)?.url == provider)
        }
    }

    @Test func `unrealized and invalid layout never creates an image request`() {
        let source = DetailArtworkSource(backdropURL: backdrop, posterFallbackURL: nil)
        for bad: CGFloat in [0, -1, .infinity, .nan] {
            #expect(DetailArtworkPolicy.rendition(for: source, width: bad, height: 500, displayScale: 2) == nil)
            #expect(DetailArtworkPolicy.rendition(for: source, width: 390, height: bad, displayScale: 2) == nil)
            #expect(DetailArtworkPolicy.rendition(for: source, width: 390, height: 500, displayScale: bad) == nil)
        }
    }
}
