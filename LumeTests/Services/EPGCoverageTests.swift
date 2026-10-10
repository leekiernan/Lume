import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct EPGCoverageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> ModelContainer {
        let schema = Schema([EPGSource.self, EPGListing.self, LiveStream.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func seed(_ container: ModelContainer, withListing: Bool = true) throws -> EPGSource {
        let context = container.mainContext
        let source = EPGSource(name: "Guide", url: "https://example.com/guide.xml")
        source.committedGeneration = 1
        source.lastSyncDate = now
        source.snapshotReferenceIDs = ["news", "event"]
        source.snapshotChannelIDs = ["news"]
        source.snapshotProgrammeCount = 1
        source.snapshotSchemaVersion = SyncFrequency.epgCurrentSchemaVersion
        source.snapshotEnd = now.addingTimeInterval(3600)
        source.validatorURL = source.url
        context.insert(source)
        context.insert(LiveStream(id: "news", streamId: 1, name: "News", epgChannelId: "news"))
        context.insert(LiveStream(id: "event", streamId: 2, name: "Event only", epgChannelId: "event"))
        if withListing {
            context.insert(EPGListing(id: "programme", channelId: "news", title: "News", listingDescription: "", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3600), sourceID: source.id))
        }
        try context.save()
        return source
    }

    @Test func `fresh sync timestamp does not hide a missing local snapshot`() throws {
        let container = try store()
        _ = try seed(container, withListing: false)
        #expect(try EPGCoverage.needsRecovery(container: container, now: now))
    }

    @Test func `fictional event channels do not request perpetual repairs`() throws {
        let container = try store()
        _ = try seed(container)
        #expect(try !EPGCoverage.needsRecovery(container: container, channelIDs: ["event"], now: now))
        #expect(try !EPGCoverage.needsRecovery(container: container, now: now))
    }

    @Test func `valid empty source is not corrupt`() throws {
        let container = try store()
        let source = try seed(container, withListing: false)
        source.snapshotChannelIDs = []
        source.snapshotProgrammeCount = 0
        try container.mainContext.save()
        #expect(try !EPGCoverage.needsRecovery(container: container, now: now))
    }

    @Test func `expired coverage is repaired independently of refresh frequency`() throws {
        let container = try store()
        _ = try seed(container)
        #expect(try EPGCoverage.needsRecovery(container: container, now: now.addingTimeInterval(3601)))
    }

    @Test func `repairs back off across launches and tolerate a backwards clock`() throws {
        let container = try store()
        let source = try seed(container, withListing: false)
        source.lastAttemptDate = now
        try container.mainContext.save()
        #expect(try !EPGCoverage.needsRecovery(container: container, now: now.addingTimeInterval(60)))
        #expect(try EPGCoverage.needsRecovery(container: container, now: now.addingTimeInterval(1800)))
        #expect(EPGCoverage.mayRepair(lastAttempt: now, now: now.addingTimeInterval(-1)))
    }

    @Test func `new channel references require a full snapshot`() throws {
        let container = try store()
        _ = try seed(container)
        container.mainContext.insert(LiveStream(id: "new", streamId: 3, name: "New", epgChannelId: "new"))
        try container.mainContext.save()
        #expect(try EPGCoverage.needsRecovery(container: container, now: now))
    }

    @Test func `conditional validation requires an intact compatible snapshot`() throws {
        let container = try store()
        let source = try seed(container)
        let context = container.mainContext
        #expect(try EPGCoverage.canValidate(source, referenceIDs: ["news", "event"], in: context, now: now))
        #expect(try !EPGCoverage.canValidate(source, referenceIDs: ["news"], in: context, now: now))
        source.snapshotProgrammeCount = 2
        #expect(try !EPGCoverage.canValidate(source, referenceIDs: ["news", "event"], in: context, now: now))
        source.snapshotProgrammeCount = 1
        source.snapshotSchemaVersion = 0
        #expect(try !EPGCoverage.canValidate(source, referenceIDs: ["news", "event"], in: context, now: now))
        source.snapshotSchemaVersion = SyncFrequency.epgCurrentSchemaVersion
        source.url = "https://example.com/other.xml"
        #expect(try !EPGCoverage.canValidate(source, referenceIDs: ["news", "event"], in: context, now: now))
    }

    @Test func `selected category detects a hole even when another channel has data`() throws {
        let container = try store()
        let source = try seed(container)
        source.snapshotChannelIDs = ["news", "event"]
        try container.mainContext.save()
        #expect(try EPGCoverage.needsRecovery(container: container, channelIDs: ["news", "event"], now: now))
    }
}
