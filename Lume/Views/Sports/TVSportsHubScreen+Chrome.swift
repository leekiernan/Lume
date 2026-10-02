//
//  TVSportsHubScreen+Chrome.swift
//  Lume
//
//  Focus-aware controls shared by the Sports Hub header.
//

#if os(tvOS)

    import SwiftUI

    /// The page-title chrome for the scope menu: bare white text at rest, a soft
    /// wash when focused. A solid white fill here would turn the heading into a
    /// button and shout over the cards.
    struct TVSportsTitleChrome<Content: View>: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content()
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(isFocused ? 0.16 : 0))
                )
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }

    /// A round icon-only control that shares the pills' rest wash and white
    /// focus fill, for actions that need no label at rest.
    struct TVSportsCircleChrome<Content: View>: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content()
                .foregroundStyle(isFocused ? .black : .white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1))))
        }
    }

#endif
