import OSLog
import SwiftData
import SwiftUI

/// One preference/control for the existing category rows on every platform.
/// Hiding a category suspends enrichment without discarding its preference.
struct CategoryEPGEnhancementControl: View {
    @Bindable var category: Category
    @Environment(\.modelContext) private var modelContext
    @AppStorage(EPGEnrichmentSettings.enabledKey) private var overallEnabled = false
    @State private var saveFailed = false

    private var selected: Bool {
        EPGEnrichmentCategories.isSelected(name: category.name, override: category.epgEnrichmentEnabled)
    }

    private var effectiveOn: Bool {
        selected && !category.isHidden && overallEnabled
    }

    var body: some View {
        Button(action: toggle) {
            HStack {
                #if os(tvOS)
                    Label("Enhance Guide", systemImage: effectiveOn ? "sparkles" : "sparkle")
                    Text(effectiveOn ? "On" : "Off")
                #else
                    Label("Enhance Guide", systemImage: effectiveOn ? "sparkles" : "sparkle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(effectiveOn ? Color.lumeAccent : Color.secondary)
                #endif
            }
        }
        #if os(tvOS)
        .buttonStyle(TVContentActionButtonStyle())
        #else
        .buttonStyle(.borderless)
        #endif
        .disabled(category.isHidden || !overallEnabled)
        .accessibilityValue(effectiveOn ? Text("On") : Text("Off"))
        .alert("Unable to Save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The guide enhancement preference could not be saved. Please try again.")
        }
    }

    private func toggle() {
        let previous = category.epgEnrichmentEnabled
        category.epgEnrichmentEnabled = !selected
        do {
            try modelContext.save()
            EPGSyncService.shared.refreshEnrichment()
        } catch {
            category.epgEnrichmentEnabled = previous
            Logger.database.warning("EPG category preference save failed: \(error.localizedDescription, privacy: .public)")
            saveFailed = true
        }
    }
}

struct CategoryEPGEnhancementHelp: View {
    var body: some View {
        Text("Enhance Guide adds available metadata to supported channels. Hidden categories are never enhanced. Turn on EPGShare metadata (experimental) in TV Guide settings first.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
