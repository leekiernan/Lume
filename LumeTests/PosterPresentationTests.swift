@testable import Lume
import SwiftUI
import Testing

@MainActor
struct PosterPresentationTests {
    @Test func `television roles follow the home search grid and detail boards`() {
        let home = PosterCardMetrics.layout(for: .rail, television: true)
        let search = PosterCardMetrics.layout(for: .search, television: true)
        let grid = PosterCardMetrics.layout(for: .grid, television: true)
        let detail = PosterCardMetrics.layout(for: .detail, television: true)
        #expect(home.width == 250 && home.height == 375 && home.spacing == 50)
        #expect(search.width == 200 && search.height == 300 && search.spacing == 40)
        #expect(grid.height == 320 && grid.spacing == 28)
        #expect(detail.width == 240 && detail.height == 360 && detail.spacing == 40)
        #expect(search.rowHeight == 356)
        #expect(home.rowHeight == 431)
        // Six cells at the reference's available width, not six on every TV.
        #expect(Int((1422 + grid.spacing) / (grid.width + grid.spacing)) == 6)
        #expect(Int((900 + grid.spacing) / (grid.width + grid.spacing)) < 6)
    }

    @Test func `every television role keeps poster proportions and lift clearance`() {
        for role in PosterCardMetrics.Presentation.allCases {
            let layout = PosterCardMetrics.layout(for: role, television: true)
            #expect(abs(layout.width / layout.height - 2 / 3) < 0.001)
            #expect(layout.railVerticalPadding >= layout.height * 0.08 / 2)
            #expect(layout.spacing >= layout.width * 0.08)
        }
    }

    @Test func `compact platforms retain their existing role geometry`() {
        for role in [PosterCardMetrics.Presentation.rail, .search, .detail] {
            let layout = PosterCardMetrics.layout(for: role, television: false)
            #expect(layout.width == 120 && layout.height == 180 && layout.spacing == 16)
            #expect(layout.rowHeight == 188)
        }
        let grid = PosterCardMetrics.layout(for: .grid, television: false)
        #expect(grid.width == 100 && grid.spacing == 16)
    }

    @Test(arguments: [CGFloat(100), 150, 213, 280])
    func `grid artwork fills its proposed cell and preserves its shape`(_ width: CGFloat) throws {
        let image = try #require(ImageRenderer(content: Rectangle()
                .posterArtworkFrame(fillsWidth: true)
                .frame(width: width)).cgImage)
        #expect(image.width == Int(width))
        #expect(abs(CGFloat(image.height) - width * 1.5) <= 1)
    }

    @Test(arguments: [CGFloat(320), 768, 1200])
    func `the shared grid adapts columns without overflowing cards`(_ width: CGFloat) throws {
        let view = PosterGrid {
            ForEach(0 ..< 12, id: \.self) { _ in
                Rectangle().posterArtworkFrame(fillsWidth: true)
            }
        }
        .frame(width: width)
        let image = try #require(ImageRenderer(content: view).cgImage)
        let spacing = PosterCardMetrics.gridSpacing
        let columns = Int((width + spacing) / (PosterCardMetrics.gridMinimum + spacing))
        let cellWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let rows = (12 + columns - 1) / columns
        let height = CGFloat(rows) * cellWidth * 1.5 + CGFloat(rows - 1) * spacing
        #expect(image.width == Int(width))
        #expect(abs(CGFloat(image.height) - height) <= 1)
    }
}
