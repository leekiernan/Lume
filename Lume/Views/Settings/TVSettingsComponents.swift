//
//  TVSettingsComponents.swift
//  Lume
//
//  Shared building blocks for the tvOS settings surfaces (Settings, Add
//  Playlist, Playlist detail). They give all three a single consistent look
//  that mirrors the Apple TV Settings app: compact rows, small uppercase
//  section labels, and the same white focus lift.
//

#if os(tvOS)

    import SwiftUI

    // MARK: - Metrics

    enum TVSettingsMetrics {
        // The Settings boards: 76-point rows of 28-point text, 18-point
        // corners, 8 points apart, on a faint white fill.
        static let rowFontSize: CGFloat = 28
        static let rowHPadding: CGFloat = 28
        static let rowVPadding: CGFloat = 14
        static let rowMinHeight: CGFloat = 76
        static let rowCornerRadius: CGFloat = 18
        static let rowSpacing: CGFloat = 8
        static let rowFill = Color.white.opacity(0.07)
        /// A focused row lifts: white, a little larger, with a shadow.
        static let focusedScale: CGFloat = 1.02
        static let labelFontSize: CGFloat = 22
        static let secondaryFontSize: CGFloat = 22
        static let statusFontSize: CGFloat = 24
        static let explanatoryFontSize: CGFloat = 22
        static let paneTitleFontSize: CGFloat = 48
        static let screenTitleFontSize: CGFloat = 38
        static let titleFontSize: CGFloat = 46
        static let pageHorizontalInset: CGFloat = 48
        static let pageVerticalInset: CGFloat = 72
        static let contentMaxWidth: CGFloat = 760
        /// Width of the Settings detail pane content: the boards run it from
        /// the sidebar to the screen's trailing inset.
        static let detailMaxWidth: CGFloat = 1280
        /// Width of a secondary column sitting beside a `contentMaxWidth` one.
        static let sideColumnWidth: CGFloat = 560
    }

    extension View {
        /// Help copy beneath a group of rows, distinct from larger status text.
        func tvSettingsFooter() -> some View {
            font(.system(size: TVSettingsMetrics.secondaryFontSize))
                .foregroundStyle(Color.lumeTextTertiary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }

        /// The focused-row lift the Settings boards draw: a soft drop shadow
        /// under a slightly enlarged row.
        func tvSettingsLift(_ isLifted: Bool) -> some View {
            scaleEffect(isLifted ? TVSettingsMetrics.focusedScale : 1)
                .shadow(color: .black.opacity(isLifted ? 0.55 : 0), radius: isLifted ? 23 : 0, y: isLifted ? 20 : 0)
        }

        /// The brand's ambient ground, shared by every tvOS settings surface.
        func tvSettingsBackground() -> some View {
            background(LumeAmbientBackground())
        }

        /// The quiet secondary line shared by the status and empty-state
        /// messages, inset to line up with the row labels above it.
        func tvSettingsSecondaryText() -> some View {
            font(.system(size: TVSettingsMetrics.statusFontSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }

        /// Error/status copy uses the same ten-foot size and row inset.
        func tvSettingsErrorText() -> some View {
            font(.system(size: TVSettingsMetrics.statusFontSize))
                .foregroundStyle(.red)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }
    }

    // MARK: - Section label

    /// A small uppercase grouped-section header.
    struct TVSettingsSectionLabel: View {
        private let title: LocalizedStringKey

        init(_ title: LocalizedStringKey) {
            self.title = title
        }

        var body: some View {
            // `.textCase` uppercases the *localized* string for display while the
            // catalog lookup still happens on the original-case key.
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: TVSettingsMetrics.labelFontSize, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.lumeTextTertiary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Read-only value row

    /// A non-interactive label/value row for read-only information. Not
    /// focusable, so the focus engine skips it and moves between the actual
    /// controls — matching the Apple TV Settings information rows.
    struct TVSettingsValueRow<Value: View>: View {
        private let label: LocalizedStringKey
        private let value: Value

        init(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) {
            self.label = label
            self.value = value()
        }

        var body: some View {
            HStack(spacing: 16) {
                Text(label)
                Spacer(minLength: 16)
                value
                    .foregroundStyle(Color.lumeTextSecondary)
            }
            .font(.system(size: TVSettingsMetrics.rowFontSize, weight: .medium))
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, TVSettingsMetrics.rowVPadding)
            .frame(maxWidth: .infinity, minHeight: TVSettingsMetrics.rowMinHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                    .fill(TVSettingsMetrics.rowFill)
            )
        }
    }

    extension TVSettingsValueRow where Value == Text {
        init(_ label: LocalizedStringKey, value: String) {
            // `value` is dynamic data (a name, URL, status), so it stays verbatim.
            self.init(label) { Text(verbatim: value) }
        }
    }

    // MARK: - Labelled text field

    /// A labelled input row. The field itself keeps the native tvOS appearance
    /// (its focus treatment is system-drawn and can't be cleanly replaced); only
    /// the small uppercase label and spacing are ours.
    struct TVSettingsField: View {
        let title: LocalizedStringKey
        let placeholder: LocalizedStringKey
        @Binding var text: String
        var isSecure: Bool = false
        var contentType: UITextContentType?
        /// Inline editors replace the control that opened them. Requesting
        /// initial focus makes that transition visible and lets tvOS scroll the
        /// newly-revealed field into view instead of jumping to the page top.
        var requestsFocusOnAppear = false
        @FocusState private var isFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: TVSettingsMetrics.labelFontSize, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.lumeTextTertiary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.system(size: TVSettingsMetrics.rowFontSize))
                .textContentType(contentType)
                .autocorrectionDisabled()
                .focused($isFocused)
                .onAppear {
                    guard requestsFocusOnAppear else { return }
                    Task {
                        await Task.yield()
                        isFocused = true
                    }
                }
            }
        }
    }

    // MARK: - Button styles

    /// A sidebar category row, from the Settings boards: secondary text at
    /// rest, Lume pink on the selection tint when selected (focus elsewhere),
    /// and white with Night text when focused.
    struct TVSettingsSidebarButtonStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let background: Color = isFocused ? .white : (isSelected ? .lumeSelection : .clear)
                let foreground: Color = isFocused ? .lumeNight : (isSelected ? .lumeAccent : .lumeTextSecondary)
                return configuration.label
                    .font(.system(size: 26, weight: isFocused || isSelected ? .semibold : .medium))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 64)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(background)
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

    /// A full-width content row: a faint resting fill that lifts to white
    /// with Night text when focused, as the Settings boards draw it.
    /// Destructive actions use system red at rest and Live red on white focus.
    struct TVSettingsRowButtonStyle: ButtonStyle {
        var isDestructive: Bool = false

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isDestructive: isDestructive)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isDestructive: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                let destructive = isDestructive || configuration.role == .destructive
                let foreground: Color = destructive ? .lumeDestructiveText(isFocused: isFocused) : (isFocused ? .lumeNight : .white)
                return configuration.label
                    .font(.system(size: TVSettingsMetrics.rowFontSize, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(foreground)
                    .opacity(isEnabled ? 1 : 0.4)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, TVSettingsMetrics.rowVPadding)
                    .frame(maxWidth: .infinity, minHeight: TVSettingsMetrics.rowMinHeight, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(isFocused ? .white : TVSettingsMetrics.rowFill)
                    )
                    .tvSettingsLift(isFocused)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

    /// A compact, auto-width action button (e.g. Add Playlist / Cancel). Quiet
    /// resting fill, light highlight with dark text on focus. `prominent` gives a
    /// slightly stronger resting fill for the primary action.
    struct TVSettingsActionButtonStyle: ButtonStyle {
        var prominent: Bool = false

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, prominent: prominent)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let prominent: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                let restFill = prominent ? Color.white.opacity(0.16) : TVSettingsMetrics.rowFill
                return configuration.label
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isFocused ? .lumeNight : .white)
                    .opacity(isEnabled ? 1 : 0.4)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(isFocused ? .white : restFill)
                    )
                    .tvSettingsLift(isFocused)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

#endif
