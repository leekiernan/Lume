//
//  RecommendationSettings.swift
//  Lume
//
//  User preferences for the "For You" recommendations feature. A small scalar
//  flag, so UserDefaults (via @AppStorage) is the right home.
//

import Foundation

nonisolated enum RecommendationSettings {
    /// Whether the "For You" row is built and shown on Home. Off by default; the
    /// user opts in from the Home layout settings (Settings › Layout › Home).
    /// Scoped to the active profile, like the row layout it controls.
    static var enabledKey: String {
        ProfileScopedPreferences.key(baseEnabledKey)
    }

    /// The unscoped form used by the profile migration/cloud snapshot.
    static let baseEnabledKey = "recommendations.enabled.v1"
    static let enabledDefault = false

    /// A counter bumped by the DEBUG-only "Recalculate" action to force an
    /// immediate recompute. Part of Home's recommendations task id; dormant (0)
    /// in release builds, where nothing increments it.
    static let manualRecalculationKey = "recommendations.manualRecalculation.v1"
}
