//
//  LumeMarkLayer.swift
//  Lume
//
//  The mark's motions as Core Animation, not per-frame SwiftUI. The render
//  server runs them, so a loader keeps moving while the main thread is busy —
//  which is exactly when loaders show (a stream opening, a catalog import) —
//  and a screen of them costs no body evaluations. Timings match
//  `LumeMarkFrame` (the brand board's keyframes).
//

import QuartzCore
import SwiftUI

final class LumeMarkLayer: CALayer {
    var motion: LumeMark.Motion = .still {
        didSet { if motion != oldValue { applyMotion(from: oldValue) } }
    }

    var reduceMotion = false {
        didSet { if reduceMotion != oldValue { applyMotion(from: motion) } }
    }

    var color: CGColor = .init(srgbRed: 1, green: 0.533, blue: 0.843, alpha: 1) {
        didSet { applyColor() }
    }

    private let core = CAShapeLayer()
    private let inner = CAShapeLayer()
    private let outer = CAShapeLayer()
    private let trace = CAShapeLayer()
    private let emits = [CAShapeLayer(), CAShapeLayer()]
    private var laidOutBounds: CGRect = .null

    override init() {
        super.init()
        for layer in [outer, trace, inner] + emits {
            layer.fillColor = nil
            addSublayer(layer)
        }
        addSublayer(core)
        trace.lineCap = .round
        applyColor()
        applyMotion(from: .still)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        guard bounds != laidOutBounds, bounds.width > 0, bounds.height > 0 else { return }
        laidOutBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let unit = min(bounds.width, bounds.height) / 240
        let centroid = CGPoint(x: bounds.midX - 10 * unit, y: bounds.midY)
        core.frame = bounds
        core.path = LumeMarkOutline(offset: LumeMarkOutline.triangle).path(in: bounds).cgPath
        for (layer, offset) in [(inner, LumeMarkOutline.innerRing), (outer, LumeMarkOutline.outerRing),
                                (trace, LumeMarkOutline.outerRing)]
        {
            layer.frame = bounds
            layer.path = LumeMarkOutline(offset: offset).path(in: bounds).cgPath
            layer.lineWidth = LumeMarkOutline.ringWidth * unit
        }
        // Emit rings scale about the triangle's centroid.
        for layer in emits {
            layer.bounds = CGRect(origin: .zero, size: bounds.size)
            layer.anchorPoint = CGPoint(x: centroid.x / bounds.width, y: centroid.y / bounds.height)
            layer.position = centroid
            layer.path = LumeMarkOutline(offset: LumeMarkOutline.triangle).path(in: layer.bounds).cgPath
            layer.lineWidth = LumeMarkOutline.ringWidth * unit
        }
        CATransaction.commit()
        // Line widths are animated in points; restart against the new size.
        if case .emit = motion { applyMotion(from: motion) }
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.fillColor = color
        for layer in [inner, outer, trace] + emits {
            layer.strokeColor = color
        }
        CATransaction.commit()
    }

    /// Restarts the motion only if the system dropped its animations (e.g.
    /// the app went to the background). Re-parenting alone keeps them —
    /// restarting there froze the mark on its first keyframe in views that
    /// rebuild often, like the player's overlays.
    func resumeIfNeeded() {
        let animated = !motion.isStatic && !reduceMotion
        let running = ([inner, outer, trace] + emits).contains { !($0.animationKeys() ?? []).isEmpty }
        if animated, !running { applyMotion(from: motion) }
    }

    /// Re-applies the current motion: after a change, or a size change.
    func applyMotion(from previous: LumeMark.Motion) {
        let effective: LumeMark.Motion = reduceMotion && !motion.isStatic ? .still : motion
        rest(at: effective)
        switch effective {
        case .still: break
        case let .progress(fraction): fill(to: fraction, from: previous)
        case .pulse: startPulse()
        case .emit: startEmit()
        case .trace: startTrace()
        case .launch: startLaunch()
        }
    }

    /// The motion's resting layer values, with every running animation gone.
    private func rest(at motion: LumeMark.Motion) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [core, inner, outer, trace] + emits {
            layer.removeAllAnimations()
        }
        let frame = LumeMarkFrame(motion: motion, elapsed: 0)
        core.opacity = 1
        inner.opacity = Float(frame.inner)
        outer.opacity = Float(frame.outer)
        trace.opacity = frame.trace == nil ? 0 : 1
        trace.strokeEnd = frame.trace ?? 0
        for layer in emits {
            layer.opacity = 0
        }
        CATransaction.commit()
    }

    /// Fills from where it was, as a sync advances.
    private func fill(to _: Double, from previous: LumeMark.Motion) {
        if case let .progress(old) = previous {
            let fill = CABasicAnimation(keyPath: "strokeEnd")
            fill.fromValue = CGFloat(min(max(old, 0), 1))
            fill.duration = 0.4
            fill.timingFunction = CAMediaTimingFunction(name: .easeOut)
            trace.add(fill, forKey: "fill")
        }
    }

    private func startPulse() {
        let pulse = keyframes("opacity", values: [0.14, 0.8, 0.14], times: [0, 0.35, 1],
                              duration: LumeMarkFrame.pulsePeriod)
        inner.opacity = 0.14
        outer.opacity = 0.14
        pulse.timeOffset = Self.phase(LumeMarkFrame.pulsePeriod)
        inner.add(pulse, forKey: "pulse")
        // The outer ring runs 1.3 s ahead (the board's -1.3 s delay).
        pulse.timeOffset += 1.3
        outer.add(pulse, forKey: "pulse")
    }

    private func startEmit() {
        let unit = min(bounds.width, bounds.height) / 240
        for (index, layer) in emits.enumerated() {
            let group = CAAnimationGroup()
            group.animations = [
                basic("transform.scale", from: 1, end: 2.2),
                basic("opacity", from: 0.8, end: 0),
                // Drawn width shrinks as the ring grows, as on the board.
                basic("lineWidth", from: 12 * unit, end: 5.5 * unit)
            ]
            group.duration = LumeMarkFrame.emitPeriod
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.4, 1)
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            group.timeOffset = Self.phase(LumeMarkFrame.emitPeriod) + Double(index)
            layer.add(group, forKey: "emit")
        }
    }

    private func startTrace() {
        let draw = keyframes("strokeEnd", values: [0, 1, 1], times: [0, 0.7, 1], duration: LumeMarkFrame.tracePeriod)
        let fade = keyframes("opacity", values: [1, 1, 0], times: [0, 0.86, 1], duration: LumeMarkFrame.tracePeriod)
        draw.timeOffset = Self.phase(LumeMarkFrame.tracePeriod)
        fade.timeOffset = draw.timeOffset
        trace.add(draw, forKey: "draw")
        trace.add(fade, forKey: "fade")
    }

    /// Once, from the static launch screen's frame to rest.
    private func startLaunch() {
        let glow = keyframes("opacity", values: [0.6, 0.6, 1, 0.6], times: [0, 0.36, 0.96, 1.8].map { $0 / 1.8 },
                             duration: 1.8, repeats: false)
        inner.add(glow, forKey: "launch")
        let outerGlow = keyframes("opacity", values: [0.3, 0.3, 0.85, 0.3],
                                  times: [0, 0.84, 1.56, 2.52].map { $0 / 2.52 }, duration: 2.52, repeats: false)
        outer.add(outerGlow, forKey: "launch")
    }

    /// Loops run on the shared media clock rather than from when they were
    /// added: a host SwiftUI rebuilds continues mid-cycle instead of
    /// restarting, and every loader on screen moves in step.
    private static func phase(_ period: TimeInterval) -> TimeInterval {
        CACurrentMediaTime().truncatingRemainder(dividingBy: period)
    }

    private func keyframes(
        _ keyPath: String, values: [Double], times: [Double], duration: TimeInterval, repeats: Bool = true
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(values.count - 1, 1))
        animation.duration = duration
        animation.repeatCount = repeats ? .infinity : 0
        animation.isRemovedOnCompletion = !repeats
        return animation
    }

    private func basic(_ keyPath: String, from start: CGFloat, end: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = start
        animation.toValue = end
        return animation
    }
}

#if os(macOS)
    import AppKit

    struct LumeMarkLayerView: NSViewRepresentable {
        let motion: LumeMark.Motion
        let color: Color

        func makeNSView(context _: Context) -> LumeMarkHostView {
            LumeMarkHostView()
        }

        func updateNSView(_ view: LumeMarkHostView, context: Context) {
            view.mark.color = color.resolve(in: context.environment).cgColor
            view.mark.reduceMotion = context.environment.accessibilityReduceMotion
            view.mark.motion = motion
        }
    }

    final class LumeMarkHostView: NSView {
        let mark = LumeMarkLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.isGeometryFlipped = true
            layer?.addSublayer(mark)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            mark.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { mark.resumeIfNeeded() }
        }
    }
#else
    import UIKit

    struct LumeMarkLayerView: UIViewRepresentable {
        let motion: LumeMark.Motion
        let color: Color

        func makeUIView(context _: Context) -> LumeMarkHostView {
            LumeMarkHostView()
        }

        func updateUIView(_ view: LumeMarkHostView, context: Context) {
            view.mark.color = color.resolve(in: context.environment).cgColor
            view.mark.reduceMotion = context.environment.accessibilityReduceMotion
            view.mark.motion = motion
        }
    }

    final class LumeMarkHostView: UIView {
        let mark = LumeMarkLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            layer.addSublayer(mark)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            mark.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { mark.resumeIfNeeded() }
        }
    }
#endif
