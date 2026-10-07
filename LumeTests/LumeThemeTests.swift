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

    @Test(arguments: [ColorScheme.light, .dark])
    func `filled accent labels use the contrasting foreground`(_ scheme: ColorScheme) {
        expectColor(.lumeOnAccent, scheme: scheme, rgb: scheme == .light ? (255, 255, 255) : (20, 16, 31))
        let foreground = luminance(.lumeOnAccent, scheme: scheme)
        let background = luminance(.lumeAccent, scheme: scheme)
        let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
        #expect(contrast >= 4.5)
    }

    @Test func `resting status accents follow the appearance while white focus uses deep pink`() {
        expectColor(.lumeFocusAwareAccent(isFocused: false), scheme: .light, rgb: (184, 35, 127))
        expectColor(.lumeFocusAwareAccent(isFocused: false), scheme: .dark, rgb: (255, 136, 215))
        for scheme in [ColorScheme.light, .dark] {
            let focused = Color.lumeFocusAwareAccent(isFocused: true)
            expectColor(focused, scheme: scheme, rgb: (184, 35, 127))
            #expect((luminance(.white, scheme: scheme) + 0.05) / (luminance(focused, scheme: scheme) + 0.05) >= 4.5)
        }
    }

    private func luminance(_ color: Color, scheme: ColorScheme) -> Double {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let resolved = color.resolve(in: environment)
        func linear(_ channel: Float) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(resolved.red) + 0.7152 * linear(resolved.green) + 0.0722 * linear(resolved.blue)
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
