import CoreGraphics
@testable import Lume
import QuartzCore
import SwiftUI
import Testing

struct LumeMarkTests {
    @Test func `outlines land on the brand board's path endpoints`() {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 240)
        let boards: [(CGFloat, [CGPoint])] = [
            (16, [CGPoint(x: -12, y: -48.5), CGPoint(x: 48, y: -13.86), CGPoint(x: -36, y: 34.64)]),
            (36, [CGPoint(x: -2, y: -65.82), CGPoint(x: 58, y: 31.18), CGPoint(x: -56, y: -34.64)]),
            (62, [CGPoint(x: 11, y: -88.33), CGPoint(x: 71, y: 53.69), CGPoint(x: -82, y: 34.64)])
        ]
        for (offset, expected) in boards {
            var points: [CGPoint] = []
            // `Path` is not a Sequence: its elements come only through forEach.
            // swiftformat:disable:next preferForLoop
            LumeMarkOutline(offset: offset).path(in: rect).forEach { element in
                switch element {
                case let .move(to: point), let .line(to: point), let .curve(to: point, _, _), let .quadCurve(to: point, _):
                    points.append(CGPoint(x: point.x - 110, y: point.y - 120))
                case .closeSubpath:
                    break
                }
            }
            // Same start as the board, so a trimmed Trace draws from there.
            #expect(abs(points[0].x - expected[0].x) < 0.01 && abs(points[0].y - expected[0].y) < 0.01)
            for point in expected {
                let nearest = points.map { hypot($0.x - point.x, $0.y - point.y) }.min() ?? .infinity
                #expect(nearest < 0.01)
            }
        }
    }

    @Test func `easing matches CSS timing functions at their ends and middle`() {
        #expect(CubicBezier.easeInOut.value(at: 0) == 0)
        #expect(abs(CubicBezier.easeInOut.value(at: 1) - 1) < 1e-6)
        #expect(abs(CubicBezier.easeInOut.value(at: 0.5) - 0.5) < 1e-3)
        // Ease-out front-loads progress.
        #expect(CubicBezier.easeOut.value(at: 0.25) > 0.25)
    }

    @Test func `keyframes interpolate between stops and hold outside them`() {
        let frames = Keyframes([(0, 0.14), (0.35, 0.8), (1, 0.14)], easing: .easeInOut)
        #expect(abs(frames.value(at: 0) - 0.14) < 1e-9)
        #expect(abs(frames.value(at: 0.35) - 0.8) < 1e-9)
        #expect(frames.value(at: 0.2) > 0.14 && frames.value(at: 0.2) < 0.8)
        #expect(abs(frames.value(at: 1.5) - 0.14) < 1e-9)
    }

    @Test func `pulse brightens the rings in turn and repeats`() {
        let peak = LumeMarkFrame(motion: .pulse, elapsed: 0.56)
        #expect(abs(peak.inner - 0.8) < 1e-6)
        #expect(peak.outer < peak.inner)
        let nextCycle = LumeMarkFrame(motion: .pulse, elapsed: 0.56 + LumeMarkFrame.pulsePeriod)
        #expect(abs(nextCycle.inner - peak.inner) < 1e-6)
        #expect(peak.core == 1)
    }

    @Test func `emit grows two staggered rings that fade as they grow`() {
        let frame = LumeMarkFrame(motion: .emit, elapsed: 0.3)
        #expect(frame.emits.count == 2)
        #expect(frame.inner == 0 && frame.outer == 0)
        let (young, old) = (frame.emits[0], frame.emits[1])
        #expect(old.scale > young.scale)
        #expect(old.opacity < young.opacity)
        #expect(young.scale >= 1 && old.scale <= 2.2)
    }

    @Test func `trace draws the outer ring then fades it`() {
        #expect(LumeMarkFrame(motion: .trace, elapsed: 0).trace == 0)
        let drawn = LumeMarkFrame(motion: .trace, elapsed: 0.7 * LumeMarkFrame.tracePeriod)
        #expect(abs((drawn.trace ?? 0) - 1) < 1e-6)
        #expect(drawn.traceOpacity == 1)
        #expect(LumeMarkFrame(motion: .trace, elapsed: 0.99 * LumeMarkFrame.tracePeriod).traceOpacity < 0.2)
    }

    @Test func `launch starts on the static launch frame and rests with the wordmark in`() {
        let first = LumeMarkFrame(motion: .launch, elapsed: 0)
        // Matches the static launch screen: rings at rest, no wordmark yet.
        #expect(first == LumeMarkFrame(motion: .still, elapsed: 0).withWordmark(0, rise: 14))
        let glowing = LumeMarkFrame(motion: .launch, elapsed: 0.96)
        #expect(abs(glowing.inner - 1) < 1e-6)
        let rested = LumeMarkFrame(motion: .launch, elapsed: 30)
        #expect(rested == LumeMarkFrame(motion: .still, elapsed: 0))
    }
}

@MainActor
struct LumeMarkLayerTests {
    private func layer(_ motion: LumeMark.Motion, reduceMotion: Bool = false) -> LumeMarkLayer {
        let mark = LumeMarkLayer()
        mark.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        mark.layoutIfNeeded()
        mark.reduceMotion = reduceMotion
        mark.motion = motion
        return mark
    }

    private func keys(_ mark: LumeMarkLayer) -> [String] {
        (mark.sublayers ?? []).flatMap { $0.animationKeys() ?? [] }.sorted()
    }

    @Test func `each motion runs on Core Animation`() {
        #expect(keys(layer(.still)).isEmpty)
        #expect(keys(layer(.pulse)) == ["pulse", "pulse"])
        #expect(keys(layer(.emit)) == ["emit", "emit"])
        #expect(keys(layer(.trace)) == ["draw", "fade"])
        #expect(keys(layer(.launch)) == ["launch", "launch"])
    }

    @Test func `reduce motion rests the mark but keeps progress`() {
        #expect(keys(layer(.pulse, reduceMotion: true)).isEmpty)
        let progress = layer(.progress(0.4), reduceMotion: true)
        #expect(progress.sublayers?.contains { ($0 as? CAShapeLayer)?.strokeEnd == 0.4 } == true)
    }

    @Test func `progress animates from its previous fill`() {
        let mark = layer(.progress(0.2))
        mark.motion = .progress(0.6)
        let trace = mark.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.strokeEnd == 0.6 }
        #expect(trace?.animation(forKey: "fill") != nil)
    }
}

private extension LumeMarkFrame {
    func withWordmark(_ opacity: Double, rise: CGFloat) -> LumeMarkFrame {
        var frame = self
        frame.wordmark = opacity
        frame.wordmarkRise = rise
        return frame
    }
}
