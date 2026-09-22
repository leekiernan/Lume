//
//  XMLTVParser.swift
//  Lume
//
//  Streaming SAX parser for XMLTV EPG payloads
//

import Foundation

/// A parsed XMLTV programme ready for direct insertion.
struct ParsedProgramme {
    let channelId: String
    let title: String
    let subtitle: String?
    let description: String
    let categories: [String]
    let start: Date
    let end: Date
}

/// Streaming SAX parser that yields batches via a callback to keep memory flat.
final nonisolated class XMLTVParser: NSObject, XMLParserDelegate {
    struct ParseOutcome {
        let programmeCount: Int
        let encounteredProgrammeCount: Int
        let succeeded: Bool
    }

    private var batch: [ParsedProgramme] = []
    private let batchSize: Int
    private let onBatch: ([ParsedProgramme]) -> Void
    private(set) var totalCount: Int = 0
    private(set) var encounteredProgrammeCount: Int = 0
    private var rootElement: String?

    private var currentStart: String?
    private var currentStop: String?
    private var currentChannel: String?
    private var currentTitle: String?
    private var currentSubtitle: String?
    private var currentDesc: String?
    private var currentCategories: [String] = []
    private var currentText: String = ""

    init(batchSize: Int = 2000, onBatch: @escaping ([ParsedProgramme]) -> Void) {
        self.batchSize = batchSize
        self.onBatch = onBatch
    }

    /// Parse an XMLTV file from disk, calling `onBatch` for every `batchSize` programmes.
    /// A malformed or unreadable document is distinct from a well-formed empty
    /// guide: callers must not publish an empty replacement for a parse error.
    static func parse(fileURL: URL, batchSize: Int = 2000, onBatch: @escaping ([ParsedProgramme]) -> Void) -> ParseOutcome {
        guard let xmlParser = XMLParser(contentsOf: fileURL) else {
            return ParseOutcome(programmeCount: 0, encounteredProgrammeCount: 0, succeeded: false)
        }
        let delegate = XMLTVParser(batchSize: batchSize, onBatch: onBatch)
        xmlParser.delegate = delegate
        let succeeded = xmlParser.parse() && delegate.rootElement == "tv"
        // Flush remaining
        if succeeded, !delegate.batch.isEmpty {
            onBatch(delegate.batch)
        }
        return ParseOutcome(
            programmeCount: delegate.totalCount,
            encounteredProgrammeCount: delegate.encounteredProgrammeCount,
            succeeded: succeeded
        )
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        if rootElement == nil { rootElement = elementName }
        currentText = ""
        if elementName == "programme" {
            encounteredProgrammeCount += 1
            currentStart = attributeDict["start"]
            currentStop = attributeDict["stop"]
            currentChannel = attributeDict["channel"]
            currentTitle = nil
            currentSubtitle = nil
            currentDesc = nil
            currentCategories = []
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if elementName == "programme" {
            if let startDate = XMLTVDate.parse(currentStart),
               let endDate = XMLTVDate.parse(currentStop),
               let channel = currentChannel,
               let title = currentTitle, !title.isEmpty
            {
                batch.append(ParsedProgramme(
                    channelId: channel,
                    title: title,
                    subtitle: currentSubtitle,
                    description: currentDesc ?? "",
                    categories: currentCategories,
                    start: startDate,
                    end: endDate
                ))
                totalCount += 1

                if batch.count >= batchSize {
                    onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            currentStart = nil
            currentStop = nil
            currentChannel = nil
            currentTitle = nil
            currentSubtitle = nil
            currentDesc = nil
            currentCategories = []
        } else if elementName == "title" {
            currentTitle = (currentTitle ?? "") + currentText
        } else if elementName == "sub-title" {
            currentSubtitle = (currentSubtitle ?? "") + currentText
        } else if elementName == "desc" {
            currentDesc = (currentDesc ?? "") + currentText
        } else if elementName == "category" {
            let category = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !category.isEmpty {
                currentCategories.append(category)
            }
        }
    }
}
