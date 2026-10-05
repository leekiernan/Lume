//
//  TVFocusLanding.swift
//  Lume
//
//  Landing focus deliberately on tvOS, instead of letting the focus engine
//  choose.
//
//  The engine picks geometrically: whatever sits nearest in the direction of
//  travel. That is right almost everywhere, and wrong in two situations this
//  file covers.
//
//  A surface that has just appeared over live content has to *take* focus, or
//  the content behind it stays live — the viewer keeps navigating a list they
//  can no longer read. Asking during the update that presents the surface never
//  works: the request names views the engine cannot see yet and is dropped. So
//  the incumbent is released, the surface is given a beat to mount, and only
//  then is the target asserted — off the focus engine's animated context.
//
//  Returning to a region the viewer has been in before has the opposite
//  problem: geometry lands them wherever they happen to be pointing, rather
//  than where they left off. `landTVFocus` asserts the remembered target in the
//  same way.
//
//  A `defaultFocus` (or `prefersDefaultFocus`) declaration states the same
//  target for the engine's own bookkeeping; it does not move focus on its own,
//  which is why the assertion here exists as well.
//

import SwiftUI

extension View {
    /// List and guide have synchronous, scoped channel queries. Yield out of
    /// the render pass before acknowledging an empty answer; a changed request
    /// or arriving channel cancels this task, just like a normal focus landing.
    func completingEmptyTVFocus(
        _ request: TVContentFocusRequest?, scope: TVContentFocusRequest.Scope,
        hasChannels: Bool, onComplete: @escaping (TVContentFocusRequest) -> Void
    ) -> some View {
        let completion = request?.emptyCompletion(in: scope, hasChannels: hasChannels)
        return task(id: completion) {
            guard let completion else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            onComplete(completion)
        }
    }
}

/// The release/settle/assert boundary is tested independently of UIKit's focus
/// engine. Cancellation or dismissal never asserts focus on a departed surface.
@MainActor
enum TVFocusLanding {
    static let settleDelay: Duration = .milliseconds(150)

    static func perform(
        release: () -> Void,
        scroll: () -> Void = {},
        assert: () -> Void,
        while stillPresented: () -> Bool = { true },
        settle: () async throws -> Void = { try await Task.sleep(for: settleDelay) }
    ) async -> Bool {
        guard !Task.isCancelled, stillPresented() else { return false }
        release()
        scroll()
        do { try await settle() } catch { return false }
        guard !Task.isCancelled, stillPresented() else { return false }
        assert()
        return true
    }
}

#if os(tvOS)
    /// Release focus, realize a lazy target without animation, then assert it
    /// outside the presenting/focus-engine update. A false result is not a claim.
    @MainActor
    @discardableResult
    func landTVFocus<Value: Hashable>(
        _ focus: FocusState<Value?>.Binding,
        on target: Value?,
        scrollingTo proxy: ScrollViewProxy? = nil,
        scrollTarget: AnyHashable? = nil,
        scrollAnchor: UnitPoint = .center,
        while stillPresented: () -> Bool = { true }
    ) async -> Bool {
        guard let target else { return false }
        return await TVFocusLanding.perform(release: { focus.wrappedValue = nil }, scroll: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy?.scrollTo(scrollTarget ?? AnyHashable(target), anchor: scrollAnchor) }
        }, assert: { focus.wrappedValue = target }, while: stillPresented)
    }

    /// The guide has one Boolean focus strip, not one native target per cell.
    @MainActor
    @discardableResult
    func landTVFocus(_ focus: FocusState<Bool>.Binding, while stillPresented: () -> Bool = { true }) async -> Bool {
        await TVFocusLanding.perform(release: { focus.wrappedValue = false }, assert: {
            focus.wrappedValue = true
        }, while: stillPresented)
    }
#endif
