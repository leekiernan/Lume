//
//  LaunchTimeline.swift
//  Lume
//
//  Where launch time goes before the first frame. Everything `LumeApp.init`
//  does — opening both stores, the index check, interrupted-sync recovery,
//  the profile fetches — runs on the main thread before SwiftUI can draw, and
//  on tvOS that was a long black screen. Each step is timed here and the
//  breakdown journalled once, when the app first draws, so a diagnostic report
//  says which step to move rather than guessing.
//

import Darwin
import Foundation
import OSLog

@MainActor
enum LaunchTimeline {
    private static var steps: [(name: String, seconds: TimeInterval)] = []
    private static var reported = false

    /// Times one launch step.
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let start = Date()
        defer { steps.append((name, Date().timeIntervalSince(start))) }
        return try work()
    }

    /// The app drew: journal the breakdown, once.
    static func firstFrame() {
        guard !reported else { return }
        reported = true
        let breakdown = steps
            .map { "\($0.name) \(String(format: "%.2f", $0.seconds))s" }
            .joined(separator: ", ")
        let sinceStart = processStart.map { Date().timeIntervalSince($0) } ?? -1
        Logger.app.info("""
        launch: first frame \(sinceStart, format: .fixed(precision: 2))s after process start — \
        \(breakdown, privacy: .public)
        """)
    }

    /// When the kernel started this process — before dyld and static
    /// initialisers, which `init` can't see.
    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()
}
