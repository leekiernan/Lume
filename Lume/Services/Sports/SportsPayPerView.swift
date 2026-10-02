//
//  SportsPayPerView.swift
//  Lume
//
//  Pay-per-view and event channels: the provider's "PPV 05", "Sky Sports Box
//  Office", "LIVE EVENT 3". They exist for one big event at a time — a title
//  fight, a WWE premium live event, a one-off — which is exactly what "Big this
//  week" is for, and most of it never appears in ESPN's scoreboards.
//
//  An event is read from the channel's guide when it has one, and otherwise
//  from the channel's own name, since providers commonly rename these channels
//  to the event they're carrying ("US (PPV 05) | UFC 310 Pantoja vs Asakura").
//  Placeholder listings ("No event", "Off air") are skipped.
//
//  The channels are classified once per catalog generation, like flagship
//  channels; only their few guides are read after that.
//

import Foundation
import SwiftData
import Synchronization

nonisolated enum SportsPayPerView {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        /// From the guide, or a time in the channel's name; `nil` when
        /// neither gives one.
        let start: Date?
        let end: Date?
        let channelName: String
        let streamId: String
        let logoURL: URL?
        /// The channel's name says LIVE.
        var isMarkedLive = false

        func isLive(at now: Date) -> Bool {
            if isMarkedLive { return true }
            guard let start, let end else { return false }
            return start <= now && end > now
        }
    }

    static let window: TimeInterval = 7 * 86400
    static let limit = 12
    /// A guide row longer than this is a filler block, not an event.
    static let longestEvent: TimeInterval = 12 * 3600

    // MARK: - Classifying

    /// Whether a channel is a pay-per-view or event channel, by its name or its
    /// category's.
    static func isPayPerView(_ name: String, categoryName: String? = nil) -> Bool {
        [name, categoryName].compactMap(\.self).contains { hasMarker(SportsMatcher.normalize($0)) }
    }

    /// "ppv", "ppv05", "pay per view", "box office", "live event", "event 3".
    private static func hasMarker(_ haystack: String) -> Bool {
        let words = haystack.split(separator: " ")
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : ""
            let previous = index > 0 ? words[index - 1] : ""
            if word.hasPrefix("ppv"), word.dropFirst(3).allSatisfy(\.isNumber) { return true }
            if word == "payperview" || (word == "pay" && next == "per") { return true }
            if word == "box", next == "office" { return true }
            if word == "event" || word == "events" {
                if previous == "live" || next.allSatisfy(\.isNumber) && !next.isEmpty { return true }
            }
        }
        return false
    }

    /// "us ppv 05", "sky sports box office", "live event 3": a marker plus a
    /// country code, a broadcaster or a number, and nothing that names an event.
    static func isMarkerOnly(_ haystack: String) -> Bool {
        guard hasMarker(haystack) else { return false }
        let filler: Set<Substring> = [
            "ppv", "pay", "per", "view", "box", "office", "live", "event", "events", "sky", "sports", "sport",
            "tnt", "dazn", "bt", "us", "usa", "uk", "ca", "au", "de", "fr", "es", "it", "nl", "ie", "hd", "fhd",
            "uhd", "4k", "sd", "channel", "the", "main"
        ]
        return SportsMatcher.normalize(haystack).split(separator: " ").allSatisfy { word in
            filler.contains(word) || word.allSatisfy(\.isNumber) || word.hasPrefix("ppv")
        }
    }

    private static let placeholders: Set<String> = [
        "no event", "no events", "no event scheduled", "off air", "offair", "to be announced", "tba", "tbd",
        "coming soon", "stay tuned", "no programme", "no program", "no information", "no info", "closed",
        "event not started", "no live event", "upcoming event"
    ]

    static func isPlaceholder(_ title: String, channelName: String) -> Bool {
        let haystack = SportsMatcher.normalize(title).trimmingCharacters(in: .whitespaces)
        if haystack.isEmpty || placeholders.contains(haystack) { return true }
        if haystack == SportsMatcher.normalize(channelName).trimmingCharacters(in: .whitespaces) { return true }
        return isMarkerOnly(" \(haystack) ")
    }

    // MARK: - Finding events

    struct Channel: Equatable {
        let streamId: String
        let name: String
        let epgChannelId: String?
        let logoURL: URL?
        /// The event the channel's category is named for, if it is.
        var categoryEvent: String?
    }

    /// A name-only event's assumed length, so "Sat 20:00" reads as live
    /// through the evening.
    static let assumedLength: TimeInterval = 3 * 3600

    private static let channelCache = Mutex<(generation: SportsChannelResolver.CacheGeneration, channels: [Channel])?>(nil)
    /// Matches the flagship result cache: heals a guide edit that didn't
    /// advance a source timestamp, without re-reading on every surface switch.
    fileprivate static let eventLifetime: TimeInterval = 10 * 60

    /// The week's events on the viewer's pay-per-view and event channels,
    /// live first, then by start; name-only events last.
    static func events(container: ModelContainer, restriction: ContentRestriction, now: Date) async -> [Event] {
        await SportsPayPerViewEventCache.shared.events(container: container, restriction: restriction, now: now)
    }

    fileprivate static func loadEvents(
        container: ModelContainer,
        restriction: ContentRestriction,
        generation: SportsChannelResolver.CacheGeneration,
        now: Date
    ) -> [Event] {
        let context = ModelContext(container)
        let channels = payPerViewChannels(context: context, generation: generation, restriction: restriction)
        return channels.isEmpty ? [] : events(on: channels, context: context, now: now)
    }

    private static func payPerViewChannels(
        context: ModelContext,
        generation: SportsChannelResolver.CacheGeneration,
        restriction: ContentRestriction
    ) -> [Channel] {
        if let cached = channelCache.withLock({ $0 }), cached.generation == generation {
            return cached.channels
        }
        let liveType = "live" // CategoryType.live; the enum is main-actor isolated
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: #Predicate { $0.typeRaw == liveType }))) ?? []
        // "PPV | PPV Events 1", and a category named for one event — "UFC
        // Fight Night | Rosas Jr vs Barcelos (Sat)" — whose channels are its feeds.
        var eventCategories: [String: String?] = [:]
        for category in categories {
            if let event = SportsEventChannelName.event(inCategory: category.name) {
                eventCategories[category.id] = .some(event)
            } else if isPayPerView("", categoryName: category.name) {
                eventCategories[category.id] = .some(nil)
            }
        }
        let streams = (try? context.fetch(SportsChannelResolver.candidateStreamDescriptor(restriction: restriction))) ?? []
        let channels = streams.compactMap { stream -> Channel? in
            let category = stream.categoryId.flatMap { eventCategories[$0] }
            guard category != nil || isPayPerView(stream.name) else { return nil }
            return Channel(
                streamId: stream.id,
                name: stream.name,
                epgChannelId: stream.epgChannelId.flatMap { $0.isEmpty ? nil : $0 },
                logoURL: stream.streamIcon.flatMap(URL.init(string:)),
                categoryEvent: category ?? nil
            )
        }
        channelCache.withLock { $0 = (generation, channels) }
        return channels
    }

    private static func events(on channels: [Channel], context: ModelContext, now: Date) -> [Event] {
        let epgIds = Array(Set(channels.compactMap(\.epgChannelId)))
        let listings = epgIds.isEmpty ? [] : (try? context.fetch(SportsChannelResolver.epgCandidateDescriptor(
            channelIds: epgIds, windowStart: now, windowEnd: now.addingTimeInterval(window)
        ))) ?? []
        let byChannel = Dictionary(grouping: listings, by: \.channelId)

        var events: [Event] = []
        var seenTitles: Set<String> = []
        for channel in channels {
            let guide = (channel.epgChannelId.flatMap { byChannel[$0] } ?? [])
                .filter { $0.end.timeIntervalSince($0.start) <= longestEvent && !isPlaceholder($0.title, channelName: channel.name) }
                .sorted { $0.start < $1.start }
            if let listing = guide.first {
                // One event per channel: its next one. A PPV channel's later
                // rows are usually that event's replays.
                let key = SportsMatcher.normalize(listing.title)
                guard seenTitles.insert(key).inserted else { continue }
                events.append(Event(
                    id: "\(channel.streamId)@\(listing.start.timeIntervalSince1970)", title: listing.title,
                    start: listing.start, end: listing.end, channelName: channel.name,
                    streamId: channel.streamId, logoURL: channel.logoURL
                ))
            } else if let event = nameEvent(on: channel, now: now) {
                guard seenTitles.insert(SportsMatcher.normalize(event.title)).inserted else { continue }
                events.append(event)
            }
        }
        return Array(order(events, now: now).prefix(limit))
    }

    /// The event a channel's name — or else its category's — carries, within
    /// the week ahead.
    static func nameEvent(on channel: Channel, now: Date) -> Event? {
        let parsed = SportsEventChannelName.parse(channel.name, now: now)
            ?? channel.categoryEvent.map { SportsEventChannelName.Parsed(title: $0, start: nil, isLive: false) }
        guard let parsed else { return nil }
        if let start = parsed.start, start.timeIntervalSince(now) > window { return nil }
        return Event(
            id: channel.streamId, title: parsed.title, start: parsed.start,
            end: parsed.start?.addingTimeInterval(assumedLength), channelName: channel.name,
            streamId: channel.streamId, logoURL: channel.logoURL, isMarkedLive: parsed.isLive
        )
    }

    static func order(_ events: [Event], now: Date) -> [Event] {
        events.sorted { lhs, rhs in
            if lhs.isLive(at: now) != rhs.isLive(at: now) { return lhs.isLive(at: now) }
            switch (lhs.start, rhs.start) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.title < rhs.title
            }
        }
    }
}

/// A PPV guide scan is small but can be requested simultaneously by the Home
/// rail, Sports Hub and a detail sheet. Keep results per viewer/catalog
/// generation and let those callers share the one scan already in progress.
private actor SportsPayPerViewEventCache {
    static let shared = SportsPayPerViewEventCache()

    private typealias Generation = SportsChannelResolver.CacheGeneration
    private typealias Entry = (events: [SportsPayPerView.Event], at: Date)

    /// A handful of generations covers profile switches without retaining old
    /// catalog scopes indefinitely. The event payload itself is at most 12 rows.
    private static let maximumEntries = 4

    private var entries: [Generation: Entry] = [:]
    private var inFlight: [Generation: Task<[SportsPayPerView.Event], Never>] = [:]

    func events(
        container: ModelContainer,
        restriction: ContentRestriction,
        now: Date
    ) async -> [SportsPayPerView.Event] {
        let context = ModelContext(container)
        let generation = Generation(container: container, context: context, restriction: restriction, picks: [:])
        discardExpiredEntries(now: now)

        if let entry = entries[generation] { return entry.events }
        if let task = inFlight[generation] { return await task.value }

        let task = Task.detached(priority: .utility) {
            SportsPayPerView.loadEvents(
                container: container, restriction: restriction, generation: generation, now: now
            )
        }
        inFlight[generation] = task
        let events = await task.value
        inFlight[generation] = nil
        entries[generation] = (events, now)
        trimEntries()
        return events
    }

    private func discardExpiredEntries(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.at) < SportsPayPerView.eventLifetime }
    }

    private func trimEntries() {
        guard entries.count > Self.maximumEntries else { return }
        let oldest = entries.min { $0.value.at < $1.value.at }?.key
        if let oldest { entries[oldest] = nil }
    }
}

nonisolated extension SportsPayPerView.Event {
    /// "Live now", the start in the viewer's time ("20:00", "Sat 22:00"), or
    /// "Time TBC" when neither the guide nor the channel's name gives one.
    func whenText(now: Date, calendar: Calendar = .current) -> String {
        if isLive(at: now) { return String(localized: "Live now") }
        guard let start else { return String(localized: "Time TBC") }
        return calendar.isDate(start, inSameDayAs: now)
            ? start.formatted(.dateTime.hour().minute())
            : start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
