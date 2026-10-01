//
//  PerfProfileBaseline.swift
//  LumePerformanceTests
//
//  The benchmarks run inside the app, so without this they measure whatever
//  the Mac or simulator running them happens to be configured as. A dev
//  install with Live TV switched off made the m3u cold import skip every
//  channel and the guide refresh skip outright — a sync doing a fraction of
//  the work, reported as a fast one.
//
//  Same rule as the unit tests' `TestProfileBaseline`: run as a fresh
//  install's default profile, where every area is enabled. Entered by the
//  first store a benchmark creates (`PerfStore.makeOnDiskContainer`); the
//  machine's own values are saved first and put back when the bundle
//  finishes. The saved copy lives in defaults too, so a run that crashed
//  mid-way is repaired at the start of the next one.
//

import Foundation
@testable import Lume
import XCTest

enum PerfProfileBaseline {
    private static let savedKey = "lumePerf.savedProfileBaseline"
    private nonisolated(unsafe) static var observer: Restorer?

    private static var keys: [String] {
        [ActiveProfileStore.key] + ProfileScopedPreferences.scopedBaseKeys
    }

    static func enter() {
        guard observer == nil else { return }
        let restorer = Restorer()
        observer = restorer
        XCTestObservationCenter.shared.addTestObserver(restorer)

        let defaults = UserDefaults.standard
        restoreSaved(in: defaults)
        var present: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { present[key] = value }
        }
        defaults.set(present, forKey: savedKey)
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }

    fileprivate static func restoreSaved(in defaults: UserDefaults) {
        guard let present = defaults.dictionary(forKey: savedKey) else { return }
        for key in keys {
            if let value = present[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: savedKey)
    }

    private final class Restorer: NSObject, XCTestObservation {
        func testBundleDidFinish(_: Bundle) {
            PerfProfileBaseline.restoreSaved(in: .standard)
        }
    }
}
