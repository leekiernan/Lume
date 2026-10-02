//
//  SportsFreshnessLabel.swift
//  Lume
//
//  "Updated 12 minutes ago" under the hub's filters — a quiet provenance cue,
//  shown only once the scores on screen are older than a refresh would leave
//  them (`SportsSyncService.freshness`), so a just-synced hub says nothing.
//  It moves on once a minute, not every second.
//

import SwiftUI

struct SportsFreshnessLabel: View {
    let fetchedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if context.date.timeIntervalSince(fetchedAt) >= SportsSyncService.freshness {
                Label {
                    Text("Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
    }
}
