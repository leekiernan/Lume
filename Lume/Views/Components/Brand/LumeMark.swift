//
//  LumeMark.swift
//  Lume
//
//  The Afterglow mark — a rounded play triangle inside two fading rings — and
//  the motions it carries for load states. Geometry and timings come from the
//  redesign's brand boards (a 240-unit artboard, CSS keyframes).
//

import SwiftUI

/// One outline of the mark. Every outline is the same sharp triangle
/// (circumradius 40 units, centroid at 110,120 of the 240-unit square — nudged
/// left so the mark sits optically centred) offset outwards by `offset`: the
/// play triangle by 16, the rings by 36 and 62. Arcs centre on the vertices.
nonisolated struct LumeMarkOutline: Shape {
    var offset: CGFloat
    /// Stroke width in artboard units; nil fills the outline.
    var lineWidth: CGFloat?
    /// Scale about the centroid (Emit's rings grow out of the triangle).
    var scale: CGFloat = 1
    /// Fraction of the outline drawn (Trace), from the same start point as
    /// the artboard's path: the end of the top-left corner.
    var trim: CGFloat = 1

    static let triangle: CGFloat = 16
    static let innerRing: CGFloat = 36
    static let outerRing: CGFloat = 62
    static let ringWidth: CGFloat = 12

    /// Lets a determinate fill animate between values.
    var animatableData: CGFloat {
        get { trim }
        set { trim = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 240
        let centroid = CGPoint(x: rect.midX - 10 * unit, y: rect.midY)
        func point(around center: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
        }
        let corners: [Double] = [0, 120, 240]
        let vertices = corners.map { point(around: centroid, radius: 40 * unit * scale, degrees: $0) }
        let radius = offset * unit * scale

        var outline = Path()
        outline.move(to: point(around: vertices[2], radius: radius, degrees: 300))
        for (corner, vertex) in zip(corners, vertices) {
            outline.addArc(center: vertex, radius: radius, startAngle: .degrees(corner - 60),
                           endAngle: .degrees(corner + 60), clockwise: false)
        }
        outline.closeSubpath()

        guard let lineWidth else { return outline }
        let drawn = trim < 1 ? outline.trimmedPath(from: 0, to: max(0, trim)) : outline
        return drawn.strokedPath(StrokeStyle(lineWidth: lineWidth * unit * scale,
                                             lineCap: trim < 1 ? .round : .butt))
    }
}

/// The mark, still or in one of its load-state motions.
struct LumeMark: View {
    enum Motion: Equatable {
        /// The resting mark.
        case still
        /// Buffering: the two rings brighten outwards in turn.
        case pulse
        /// Going live: rings expand out of the play triangle and fade.
        case emit
        /// Progress: the outer ring draws itself around the mark.
        case trace
        /// App start: the rings glow outwards once, then rest.
        case launch
        /// Determinate progress: the outer ring filled to `fraction` (0...1).
        case progress(Double)

        /// Drawn from state alone, with no running clock.
        var isStatic: Bool {
            switch self {
            case .still, .progress: true
            default: false
            }
        }
    }

    var motion: Motion = .still
    var color: Color = .lumeAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: motion.isStatic || reduceMotion)) { context in
            let elapsed = reduceMotion ? 0 : context.date.timeIntervalSince(start)
            frame(LumeMarkFrame(motion: reduceMotion && !motion.isStatic ? .still : motion, elapsed: elapsed))
        }
        .animation(.easeOut(duration: 0.4), value: motion)
        .foregroundStyle(color)
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: motion) { start = Date() }
    }

    private func frame(_ frame: LumeMarkFrame) -> some View {
        ZStack {
            ForEach(Array(frame.emits.enumerated()), id: \.offset) { _, emit in
                LumeMarkOutline(offset: LumeMarkOutline.triangle, lineWidth: emit.lineWidth, scale: emit.scale)
                    .opacity(emit.opacity)
            }
            LumeMarkOutline(offset: LumeMarkOutline.outerRing, lineWidth: LumeMarkOutline.ringWidth)
                .opacity(frame.outer)
            if let trace = frame.trace {
                LumeMarkOutline(offset: LumeMarkOutline.outerRing, lineWidth: LumeMarkOutline.ringWidth, trim: trace)
                    .opacity(frame.traceOpacity)
            }
            LumeMarkOutline(offset: LumeMarkOutline.innerRing, lineWidth: LumeMarkOutline.ringWidth)
                .opacity(frame.inner)
            LumeMarkOutline(offset: LumeMarkOutline.triangle)
                .opacity(frame.core)
        }
    }
}

/// The mark's layer state at a moment of a motion: a pure function of time,
/// ported from the brand board's keyframes (CSS easing per segment).
nonisolated struct LumeMarkFrame: Equatable {
    struct Emit: Equatable {
        var scale: CGFloat
        var opacity: Double
        var lineWidth: CGFloat
    }

    var core = 1.0
    var inner = 0.6
    var outer = 0.3
    var trace: CGFloat?
    var traceOpacity = 1.0
    var emits: [Emit] = []
    /// The wordmark's arrival during `.launch` (opacity, and rise in points
    /// at the launch size).
    var wordmark = 1.0
    var wordmarkRise: CGFloat = 0

    static let pulsePeriod = 1.6
    static let emitPeriod = 2.0
    static let tracePeriod = 2.8
    /// The launch intro's length; it rests afterwards.
    static let launchDuration = 2.8

    init(motion: LumeMark.Motion, elapsed: TimeInterval) {
        switch motion {
        case .still:
            break
        case .pulse:
            let pulse = Keyframes([(0, 0.14), (0.35, 0.8), (1, 0.14)], easing: .easeInOut)
            inner = pulse.value(at: Self.phase(elapsed, Self.pulsePeriod))
            // The outer ring runs 1.3 s ahead (the board's -1.3 s delay).
            outer = pulse.value(at: Self.phase(elapsed + 1.3, Self.pulsePeriod))
        case .emit:
            inner = 0
            outer = 0
            let curve = CubicBezier(0.2, 0.6, 0.4, 1)
            emits = [0.0, 1.0].map { lead in
                let eased = curve.value(at: Self.phase(elapsed + lead, Self.emitPeriod))
                return Emit(scale: 1 + 1.2 * eased, opacity: 0.8 * (1 - eased),
                            lineWidth: 12 + (5.5 - 12) * eased)
            }
        case .trace:
            outer = 0.15
            let phase = Self.phase(elapsed, Self.tracePeriod)
            trace = Keyframes([(0, 0), (0.7, 1), (1, 1)], easing: .easeInOut).value(at: phase)
            traceOpacity = Keyframes([(0, 1), (0.86, 1), (1, 0)], easing: .easeInOut).value(at: phase)
        case let .progress(fraction):
            outer = 0.15
            trace = CGFloat(min(max(fraction, 0), 1))
        case .launch:
            // The board's 6 s loop, played once to its resting hold. The core
            // is already up: the static launch screen shows it.
            let seconds = min(elapsed, Self.launchDuration)
            inner = Keyframes([(0, 0.6), (0.36, 0.6), (0.96, 1), (1.8, 0.6), (6, 0.6)], easing: .easeInOut)
                .value(at: seconds / 6, scale: 6)
            outer = Keyframes([(0, 0.3), (0.84, 0.3), (1.56, 0.85), (2.52, 0.3), (6, 0.3)], easing: .easeInOut)
                .value(at: seconds / 6, scale: 6)
            let arrival = Keyframes([(0, 0), (1.92, 0), (2.76, 1), (6, 1)], easing: .easeOut)
                .value(at: seconds / 6, scale: 6)
            wordmark = arrival
            wordmarkRise = 14 * (1 - arrival)
        }
    }

    private static func phase(_ elapsed: TimeInterval, _ period: TimeInterval) -> Double {
        let value = elapsed.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }
}

/// CSS-style keyframes: stops at fractions of the cycle, eased per segment.
nonisolated struct Keyframes {
    let stops: [(at: Double, value: Double)]
    let easing: CubicBezier

    init(_ stops: [(Double, Double)], easing: CubicBezier) {
        self.stops = stops.map { (at: $0.0, value: $0.1) }
        self.easing = easing
    }

    /// The value at `fraction` of the cycle. `scale` re-expresses stops given
    /// in seconds over a cycle of that many seconds.
    func value(at fraction: Double, scale: Double = 1) -> Double {
        let position = fraction * scale
        guard let first = stops.first else { return 0 }
        if position <= first.at { return first.value }
        for (lower, upper) in zip(stops, stops.dropFirst()) where position <= upper.at {
            let span = upper.at - lower.at
            let local = span > 0 ? (position - lower.at) / span : 1
            return lower.value + (upper.value - lower.value) * easing.value(at: local)
        }
        return stops.last?.value ?? first.value
    }
}

/// A CSS `cubic-bezier()` timing function, from its two control points.
nonisolated struct CubicBezier {
    let first: CGPoint
    let second: CGPoint

    init(_ firstX: Double, _ firstY: Double, _ secondX: Double, _ secondY: Double) {
        first = CGPoint(x: firstX, y: firstY)
        second = CGPoint(x: secondX, y: secondY)
    }

    static let easeInOut = CubicBezier(0.42, 0, 0.58, 1)
    static let easeOut = CubicBezier(0, 0, 0.58, 1)

    func value(at progress: Double) -> Double {
        let target = min(max(progress, 0), 1)
        // Solve curveX(time) = target by bisection: monotonic while both
        // control points' x lie within 0...1, as CSS requires.
        var low = 0.0, high = 1.0, time = target
        for _ in 0 ..< 24 {
            let current = Self.coordinate(time, first.x, second.x)
            if abs(current - target) < 1e-5 { break }
            if current < target { low = time } else { high = time }
            time = (low + high) / 2
        }
        return Self.coordinate(time, first.y, second.y)
    }

    /// One coordinate of the curve from (0,0) to (1,1) at `time`.
    private static func coordinate(_ time: Double, _ control1: Double, _ control2: Double) -> Double {
        let rest = 1 - time
        return 3 * rest * rest * time * control1 + 3 * rest * time * time * control2 + time * time * time
    }
}
