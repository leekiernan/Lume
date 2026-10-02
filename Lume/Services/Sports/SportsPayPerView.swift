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
        /// From the guide; `nil` when the event came from the channel name.
        let start: Date?
        let end: Date?
        let channelName: String
        let streamId: String
        let logoURL: URL?

        func isLive(at now: Date) -> Bool {
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

    /// The event a channel's name carries, if the provider put one there.
    static func title(fromChannelName name: String) -> String? {
        let segments = name
            .split(whereSeparator: { "|:()[]".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let candidates = segments.filter { segment in
            let haystack = SportsMatcher.normalize(segment)
            let words = haystack.split(separator: " ")
            let letters = segment.unicodeScalars.filter(CharacterSet.letters.contains).count
            return words.count >= 2 && letters >= 6 && !isMarkerOnly(haystack)
        }
        return candidates.max { $0.count < $1.count }
    }

    /// "us ppv 05", "sky sports box office", "live event 3": a marker plus a
    /// country code, a broadcaster or a number, and nothing that names an event.
    private static func isMarkerOnly(_ haystack: String) -> Bool {
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
    }

    private static let channelCache = Mutex<(generation: SportsChannelResolver.CacheGeneration, channels: [Channel])?>(nil)
    private static let eventCache = Mutex<(generation: SportsChannelResolver.CacheGeneration, events: [Event], at: Date)?>(nil)
    /// Matches the flagship result cache: heals a guide edit that didn't
    /// advance a source timestamp, without re-reading on every surface switch.
    private static let eventLifetime: TimeInterval = 10 * 60

    /// The week's events on the viewer's pay-per-view and event channels,
    /// live first, then by start; name-only events last.
    static func events(container: ModelContainer, restriction: ContentRestriction, now: Date) async -> [Event] {
        await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let generation = SportsChannelResolver.CacheGeneration(
                container: container, context: context, restriction: restriction, picks: [:]
            )
            if let cached = eventCache.withLock({ $0 }), cached.generation == generation,
               now.timeIntervalSince(cached.at) < eventLifetime
            {
                return cached.events
            }
            let channels = payPerViewChannels(context: context, generation: generation, restriction: restriction)
            let events = channels.isEmpty ? [] : events(on: channels, context: context, now: now)
            eventCache.withLock { $0 = (generation, events, now) }
            return events
        }.value
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
        let ppvCategoryIds = Set(categories.filter { isPayPerView("", categoryName: $0.name) }.map(\.id))
        let streams = (try? context.fetch(SportsChannelResolver.candidateStreamDescriptor(restriction: restriction))) ?? []
        let channels = streams.compactMap { stream -> Channel? in
            let inCategory = stream.categoryId.map(ppvCategoryIds.contains) ?? false
            guard inCategory || isPayPerView(stream.name) else { return nil }
            return Channel(
                streamId: stream.id,
                name: stream.name,
                epgChannelId: stream.epgChannelId.flatMap { $0.isEmpty ? nil : $0 },
                logoURL: stream.streamIcon.flatMap(URL.init(string:))
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
            } else if let title = title(fromChannelName: channel.name) {
                guard seenTitles.insert(SportsMatcher.normalize(title)).inserted else { continue }
                events.append(Event(
                    id: channel.streamId, title: title, start: nil, end: nil, channelName: channel.name,
                    streamId: channel.streamId, logoURL: channel.logoURL
                ))
            }
        }
        return Array(order(events, now: now).prefix(limit))
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

nonisolated extension SportsPayPerView.Event {
    /// "Live now", the start ("20:00", "Sat 22:00"), or — for an event read
    /// from the channel's name — that it's on the channel.
    func whenText(now: Date, calendar: Calendar = .current) -> String {
        if isLive(at: now) { return String(localized: "Live now") }
        guard let start else { return String(localized: "Listed on the channel") }
        return calendar.isDate(start, inSameDayAs: now)
            ? start.formatted(.dateTime.hour().minute())
            : start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
