// Shared option rows for Settings, engine options, Sports and playlist detail.
// These preserve the existing flat, full-width tvOS focus geometry.

#if os(tvOS)
    import SwiftUI

    /// Presentation only: rich source subtitles, saves and focus restoration
    /// remain owned by the button's host rather than a generic toggle action.
    struct TVSettingsToggleLabel<Title: View>: View {
        let isOn: Bool
        var showsIndicator = false
        @ViewBuilder let title: () -> Title

        var body: some View {
            HStack(spacing: 16) {
                if showsIndicator {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                }
                title()
                Spacer(minLength: 0)
                Text(isOn ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A flat toggle row matching the Apple-TV settings rows: shows On/Off and
    /// flips on Select.
    struct TVOptionToggleRow: View {
        let title: LocalizedStringKey
        @Binding var isOn: Bool
        var showsIndicator = false

        var body: some View {
            Button { isOn.toggle() } label: {
                TVSettingsToggleLabel(isOn: isOn, showsIndicator: showsIndicator) {
                    Text(title)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .accessibilityValue(isOn ? Text("On") : Text("Off"))
        }
    }

    /// A flat row that cycles through a fixed set of choices on each Select,
    /// showing the current choice's label on the right. tvOS has no good inline
    /// picker, and a full sub-list per option would bury the settings, so the
    /// row advances to the next value in place.
    struct TVOptionCycleRow: View {
        let title: LocalizedStringKey
        let valueLabel: String
        let onAdvance: () -> Void

        var body: some View {
            Button(action: onAdvance) {
                HStack(spacing: 16) {
                    Text(title)
                    Spacer(minLength: 0)
                    Text(verbatim: valueLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }

    /// A flat destructive-styled row used to trigger a reset on tvOS.
    struct TVOptionResetRow: View {
        let title: LocalizedStringKey
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    Text(title)
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }
#endif
