//
//  FilterChips.swift
//  Lume
//
//  A row of pill choices — the redesign's filter and tab control. Selected is
//  Lume pink on a pink tint; at rest a quiet surface; on tvOS focus is the
//  system's white lift (white fill, dark text), as `TVGlassButtonStyle` draws
//  it. Native buttons underneath, so focus and accessibility are the system's.
//

import SwiftUI

struct FilterChips<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> Text

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FilterChipMetrics.spacing) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selection
                    Button {
                        selection = option
                    } label: {
                        label(option)
                    }
                    .buttonStyle(FilterChipStyle(isSelected: isSelected))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            #if os(tvOS)
            // Room for the focus lift and its shadow.
            .padding(.vertical, 12)
            #endif
        }
        .scrollClipDisabled()
    }
}

struct FilterChipStyle: ButtonStyle {
    enum ChipShape {
        /// Filters (Search, match detail tabs).
        case capsule
        /// Tabs over content (seasons, the player's panels).
        case tab
    }

    let isSelected: Bool
    var shape: ChipShape = .capsule

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, isSelected: isSelected, shape: shape)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let shape: ChipShape
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(FilterChipMetrics.font(selected: isSelected))
                .lineLimit(1)
                .padding(.horizontal, FilterChipMetrics.horizontalPadding)
                .frame(height: FilterChipMetrics.height)
                .foregroundStyle(foreground)
                .background(outline.fill(background))
                .contentShape(outline)
            #if os(tvOS)
                .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: 18, y: 10)
                .scaleEffect(isFocused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
            #else
                .opacity(configuration.isPressed ? 0.7 : 1)
            #endif
        }

        private var outline: AnyShape {
            switch shape {
            case .capsule: AnyShape(Capsule())
            case .tab: AnyShape(RoundedRectangle(cornerRadius: FilterChipMetrics.tabCornerRadius, style: .continuous))
            }
        }

        private var foreground: Color {
            #if os(tvOS)
                if isFocused { return .lumeNight }
            #endif
            return isSelected ? .lumeAccent : .primary
        }

        private var background: AnyShapeStyle {
            #if os(tvOS)
                if isFocused { return AnyShapeStyle(.white) }
                return isSelected ? AnyShapeStyle(Color.lumeSelection) : AnyShapeStyle(.white.opacity(0.10))
            #else
                return isSelected ? AnyShapeStyle(Color.lumeSelection) : AnyShapeStyle(.fill.tertiary)
            #endif
        }
    }
}

enum FilterChipMetrics {
    #if os(tvOS)
        static let height: CGFloat = 60
        static let horizontalPadding: CGFloat = 28
        static let spacing: CGFloat = 12
        static let tabCornerRadius: CGFloat = 14
        static func font(selected: Bool) -> Font {
            .system(size: 26, weight: selected ? .semibold : .medium)
        }
    #else
        static let height: CGFloat = 32
        static let horizontalPadding: CGFloat = 14
        static let spacing: CGFloat = 8
        static let tabCornerRadius: CGFloat = 8
        static func font(selected: Bool) -> Font {
            .subheadline.weight(selected ? .semibold : .medium)
        }
    #endif
}
