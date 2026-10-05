import Foundation
@testable import Lume
import Testing

struct HeroArtworkPolicyTests {
    @Test func `compact composition shares one breakpoint and bottom fade`() {
        #expect(HeroArtworkPolicy.isCompact(width: 599))
        #expect(!HeroArtworkPolicy.isCompact(width: 600))
        #expect(!HeroArtworkPolicy.isCompact(width: 1920))
        #expect(HeroArtworkPolicy.compactFadeStart == 0.65)
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func `render and prefetch share portrait rendition and pixel cache identity`(scale: Double) throws {
        let displayScale = CGFloat(scale)
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/original/poster.jpg"))
        let rendition = HeroArtworkPolicy.rendition(
            url: url, width: 390, height: 675, sourceRatio: HeroArtworkPolicy.portraitRatio,
            zoom: HeroArtworkPolicy.portraitZoom, displayScale: displayScale
        )
        #expect(rendition.decodeSizeInPoints == 843.75)
        #expect(rendition.decodeSizeInPixels == rendition.decodeSizeInPoints * displayScale)
        #expect(rendition.url == HeroArtworkPolicy.posterURL(url, pixelWidth: rendition.decodeSizeInPixels * HeroArtworkPolicy.portraitRatio))
        let sizedURL = try #require(rendition.url)
        #expect(ImagePipeline.memoryKey(sizedURL, maxPixelSize: rendition.decodeSizeInPoints * displayScale)
            == ImagePipeline.memoryKey(sizedURL, maxPixelSize: rendition.decodeSizeInPixels))
    }

    @Test func `wide rendition retains full resolution and provider identity`() throws {
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/wide.jpg"))
        let rendition = HeroArtworkPolicy.rendition(url: url, width: 1920, height: 1080, displayScale: 2)
        #expect(rendition.url?.path == "/t/p/original/wide.jpg")
        #expect(rendition.decodeSizeInPoints == 1920)
        #expect(rendition.decodeSizeInPixels == 3840)
        let provider = try #require(URL(string: "https://provider.test/hero.jpg?auth=value"))
        #expect(HeroArtworkPolicy.rendition(url: provider, width: 390, height: 220, displayScale: 3).url == provider)
        #expect(HeroArtworkPolicy.rendition(url: nil, width: 390, height: 220, displayScale: 3).url == nil)
    }

    @Test func `zoomed compact movie heroes gain height without changing sports or wide layouts`() {
        #expect(HeroArtworkPolicy.portraitZoom == 1.25)
        #expect(HeroArtworkPolicy.heroHeight(width: 390, portraitComposition: true) == 675)
        #expect(HeroArtworkPolicy.heroHeight(width: 390) == 540)
        #expect(HeroArtworkPolicy.heroHeight(width: 599, portraitComposition: true) == 780)
        #expect(HeroArtworkPolicy.heroHeight(width: 600, portraitComposition: true) == 800)
        #expect(HeroArtworkPolicy.heroHeight(width: 1920, portraitComposition: true) == 800)
    }

    @Test func `only narrow heroes select portrait artwork`() throws {
        let poster = try #require(URL(string: "https://image.tmdb.org/t/p/original/poster.jpg"))
        #expect(HeroArtworkPolicy.portraitURL(poster, width: 390) == poster)
        #expect(HeroArtworkPolicy.portraitURL(poster, width: 599) == poster)
        #expect(HeroArtworkPolicy.portraitURL(poster, width: 600) == nil)
        #expect(HeroArtworkPolicy.portraitURL(poster, width: 1920) == nil)
        #expect(HeroArtworkPolicy.portraitURL(nil, width: 390) == nil)
    }

    @Test func `portrait download tiers use poster sizes and preserve identity`() throws {
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/original/poster.jpg?test=1"))
        for (width, size) in [(342.0, "w342"), (343, "w500"), (500, "w500"), (501, "w780"), (780, "w780"), (781, "original")] {
            let result = HeroArtworkPolicy.posterURL(url, pixelWidth: width)
            #expect(result?.path == "/t/p/\(size)/poster.jpg")
            #expect(result?.query == "test=1")
        }
        #expect(HeroArtworkPolicy.decodePoints(width: 390, height: 540, sourceRatio: HeroArtworkPolicy.portraitRatio) == 585)
        let external = try #require(URL(string: "https://example.com/poster.jpg"))
        #expect(HeroArtworkPolicy.posterURL(external, pixelWidth: 1000) == external)
    }

    @Test func `compact artwork preserves landscape ratio without changing wide heroes`() {
        #expect(HeroArtworkPolicy.heroHeight(width: 390) == 540)
        #expect(HeroArtworkPolicy.heroHeight(width: 1024) == 800)
        let landscapeHeight: CGFloat = 390 * 9 / 16
        #expect(HeroArtworkPolicy.artworkHeight(width: 390, heroHeight: 800) == landscapeHeight)
        #expect(HeroArtworkPolicy.artworkHeight(width: 1024, heroHeight: 800) == 800)
        #expect(HeroArtworkPolicy.artworkHeight(width: 1920, heroHeight: 1080) == 1080)
        #expect(HeroArtworkPolicy.artworkHeight(width: 390, heroHeight: 100) == 100)
    }

    @Test func `output pixels distinguish HD and UHD without device identity`() throws {
        let points = HeroArtworkPolicy.decodePoints(width: 1920, height: 1080)
        #expect(points == 1920)
        #expect(points * 2 == 3840)
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/w1920/hero.jpg"))
        #expect(HeroArtworkPolicy.backdropURL(url, pixelWidth: points)?.path == "/t/p/original/hero.jpg")
        #expect(HeroArtworkPolicy.backdropURL(url, pixelWidth: points * 2)?.path == "/t/p/original/hero.jpg")
        // Both need original bytes; decoding is bounded separately at 1920/3840.
    }

    @Test func `download tiers preserve artwork identity and query`() throws {
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/original/hero.jpg?test=1"))
        for (pixels, size) in [(300.0, "w300"), (301, "w780"), (780, "w780"), (781, "w1280"), (1280, "w1280"), (1281, "original")] {
            let result = HeroArtworkPolicy.backdropURL(url, pixelWidth: pixels)
            #expect(result?.path == "/t/p/\(size)/hero.jpg")
            #expect(result?.query == "test=1")
        }
    }

    @Test func `external artwork and logos are not rewritten`() throws {
        for raw in ["https://www.thesportsdb.com/images/fanart.jpg", "https://image.tmdb.org/t/p/w500/poster.jpg", "https://image.tmdb.org/t/p/original/logo.svg"] {
            let url = try #require(URL(string: raw))
            #expect(HeroArtworkPolicy.backdropURL(url, pixelWidth: 4000) == url)
        }
        #expect(HeroArtworkPolicy.backdropURL(nil, pixelWidth: 1000) == nil)
    }

    @Test func `decode sizing accounts for the fill crop on wide artwork regions`() {
        let landscapeHeight: CGFloat = 390 * 9 / 16
        let croppedWidth: CGFloat = 800 * 16 / 9
        #expect(HeroArtworkPolicy.decodePoints(width: 390, height: landscapeHeight) == 390)
        #expect(abs(HeroArtworkPolicy.decodePoints(width: 600, height: 800) - croppedWidth) < 0.001)
    }
}
