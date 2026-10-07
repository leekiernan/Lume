import SwiftUI

/// The same management rows/gestures as Sports and library management; provider
/// categories remain a separate destination below these editorial sections.
struct LiveTVSectionsSettings: View {
    var proxy: ScrollViewProxy?
    @AppStorage(LiveTVHubLayout.orderKey) private var orderRaw = ""
    @AppStorage(LiveTVHubLayout.hiddenKey) private var hiddenRaw = ""
    #if os(tvOS)
        @State private var isReordering = false
    #endif

    private var rows: [LiveTVHubRow] {
        LiveTVHubLayout.rows(orderRaw: orderRaw)
    }

    private var hidden: Set<String> {
        Set(SectionTokens.decode(hiddenRaw))
    }

    var body: some View {
        #if os(tvOS)
            if let proxy {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Sections")
                    TVReorderableContentList(items: rows, title: { $0.title }, isHidden: { hidden.contains($0.id) },
                                             onToggleHidden: { hiddenRaw = SectionTokens.toggling($0.id, in: hiddenRaw) },
                                             onCommitOrder: { orderRaw = SectionTokens.encode($0.map(\.id)) },
                                             isReordering: $isReordering, scrollProxy: proxy, icon: { $0.systemImage })
                    footer.tvSettingsFooter()
                }
            }
        #else
            Section {
                ForEach(rows) { row in
                    ContentManageRow(title: row.title, isHidden: hidden.contains(row.id),
                                     onToggleHidden: { hiddenRaw = SectionTokens.toggling(row.id, in: hiddenRaw) },
                                     icon: { Image(systemName: row.systemImage) })
                }
                .onMove { source, destination in
                    var reordered = rows
                    reordered.move(fromOffsets: source, toOffset: destination)
                    orderRaw = SectionTokens.encode(reordered.map(\.id))
                }
            } header: { Text("Sections") } footer: { footer }
        #endif
    }

    private var footer: Text {
        Text("Hide and reorder the Live TV home sections. Each appears only when it has something to show. Country selections use the channels available in your playlist.")
    }
}

#if os(tvOS)
    extension LiveTVHubRow: ReorderableRowItem {}
#endif
