//
//  LumeProgressViewStyle.swift
//  Lume
//
//  Every indeterminate `ProgressView` in the app draws the mark's Pulse
//  instead of the system spinner. Applied once at the scene roots, so call
//  sites keep the native API (labels, `controlSize`, layout). Determinate
//  progress keeps the system's linear bar.
//

import SwiftUI

struct LumeProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if configuration.fractionCompleted == nil {
            LumeLoader(label: configuration.label.map { AnyView($0) })
        } else {
            ProgressView(configuration)
                .progressViewStyle(.linear)
        }
    }
}

/// The Pulse loader, sized from the environment's control size.
struct LumeLoader: View {
    var label: AnyView?
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        if let label {
            VStack(spacing: spacing) {
                mark
                label
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else {
            mark
                .accessibilityElement()
                .accessibilityLabel(Text("Loading…"))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var mark: some View {
        LumeMark(motion: .pulse)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }

    /// Close to the system spinner at each size, so layouts built around it
    /// keep their spacing.
    private var side: CGFloat {
        #if os(tvOS)
            switch controlSize {
            case .mini: 28
            case .small: 36
            case .large: 72
            case .extraLarge: 96
            default: 48
            }
        #else
            switch controlSize {
            case .mini: 14
            case .small: 18
            case .large: 36
            case .extraLarge: 48
            default: 24
            }
        #endif
    }

    private var spacing: CGFloat {
        #if os(tvOS)
            16
        #else
            8
        #endif
    }
}

extension View {
    /// The brand loader for every indeterminate `ProgressView` below.
    func lumeProgressViews() -> some View {
        progressViewStyle(LumeProgressViewStyle())
    }
}
