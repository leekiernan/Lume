//
//  PlaybackPolicy.swift
//  Lume
//
//  How long a stream gets and what a failure earns, the same for every
//  engine. Each engine used to carry its own copy — and its own answer to "a
//  hard error before the first frame on the last engine": KSPlayer spent its
//  reconnect budget, the other three gave up at once.
//

import Foundation

nonisolated enum PlaybackPolicy {
    /// How long to wait for a first frame. Engines legitimately sit in
    /// preparing / buffering for 10–20 s on a healthy open, so this is well
    /// clear of that.
    static let startupTimeout: TimeInterval = 40
    /// The same wait when another engine is left to try: no point watching a
    /// black screen for the full window when the next engine might play it.
    static let quickStartupTimeout: TimeInterval = 15
    /// How long a live stream may sit buffering after it started before it is
    /// rebuilt. A healthy rebuffer only has to refill a few seconds.
    static let liveStallTimeout: TimeInterval = 30

    static func startupTimeout(quick: Bool) -> TimeInterval {
        quick ? quickStartupTimeout : startupTimeout
    }

    /// Whether a hard error before the first frame goes through the reconnect
    /// budget. With another engine left it's a definitive "this engine can't"
    /// and the session falls back at once; on the last engine a retry is the
    /// only thing left to try.
    static func retriesStartupError(canFallBack: Bool) -> Bool {
        !canFallBack
    }
}
