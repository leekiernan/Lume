@testable import Lume
import SwiftUI
import Testing

@MainActor
struct DesignControlLayoutTests {
    @Test func `filter chips have a touch target and grow with accessibility text`() throws {
        let standard = try chipSize(at: .large)
        let accessible = try chipSize(at: .accessibility5)
        #expect(standard.height >= 44)
        #expect(accessible.height > standard.height)
        #expect(accessible.width > standard.width)
    }

    @Test func `the shared detail icon is at least a touch target`() throws {
        let renderer = ImageRenderer(content: GlassIconButton(systemImage: "heart", accessibilityLabel: "Favorite", action: {}))
        let image = try #require(renderer.cgImage)
        #expect(image.width >= 44)
        #expect(image.height >= 44)
    }

    private func chipSize(at size: DynamicTypeSize) throws -> CGSize {
        let renderer = ImageRenderer(content:
            Button("Movies", action: {})
                .buttonStyle(FilterChipStyle(isSelected: false))
                .dynamicTypeSize(size))
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }
}
