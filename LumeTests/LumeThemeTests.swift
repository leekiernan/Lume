@testable import Lume
import SwiftUI
import Testing

@MainActor
struct LumeThemeTests {
    @Test func `destructive text follows the light and dark foundations`() {
        expectColor(.lumeDestructiveText(isFocused: false), scheme: .light, rgb: (215, 38, 61))
        expectColor(.lumeDestructiveText(isFocused: false), scheme: .dark, rgb: (255, 69, 58))
    }

    @Test func `white focus uses Live red regardless of the device appearance`() {
        for scheme in [ColorScheme.light, .dark] {
            expectColor(.lumeDestructiveText(isFocused: true), scheme: scheme, rgb: (215, 38, 61))
        }
    }

    @Test func `selection and accent retain their contrasting light and dark variants`() {
        expectColor(.lumeAccent, scheme: .light, rgb: (184, 35, 127))
        expectColor(.lumeAccent, scheme: .dark, rgb: (255, 136, 215))
        expectColor(.lumeSelection, scheme: .light, rgb: (184, 35, 127), alpha: 0.10)
        expectColor(.lumeSelection, scheme: .dark, rgb: (255, 136, 215), alpha: 0.18)
    }

    private func expectColor(_ color: Color, scheme: ColorScheme, rgb: (Int, Int, Int), alpha: Float = 1) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let resolved = color.resolve(in: environment)
        #expect(abs(resolved.red - Float(rgb.0) / 255) < 0.005)
        #expect(abs(resolved.green - Float(rgb.1) / 255) < 0.005)
        #expect(abs(resolved.blue - Float(rgb.2) / 255) < 0.005)
        #expect(abs(resolved.opacity - alpha) < 0.005)
    }
}
