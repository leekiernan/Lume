//
//  HomeView+Navigation.swift
//  Lume
//
//  Home's navigation stack, driven from `DeepLinkRouter` so a pushed detail
//  screen survives the tab being unmounted (see `IdleUnmountingTab`). Split out
//  of HomeView.swift, which sits at SwiftLint's file-length limit.
//

import SwiftUI

extension HomeView {
    /// Previews use a local path; the app's path outlives tab unmounting.
    var homePath: Binding<NavigationPath> {
        DetailNavigation.pathBinding(in: pathRouter, at: \.homePath, fallback: $fallbackHomePath)
    }
}
