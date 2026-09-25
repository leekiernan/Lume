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
    private var currentTitle = LocalizedText()
    private var currentSubtitle = LocalizedText()
    private var currentDesc = LocalizedText()
    private var currentCategories: [String] = []
    private var currentText: String = ""
    /// The `lang` attribute of the text element being read.
    private var currentLang: String?
    /// The language code (`de`, `en`, …) a repeated element should prefer.
    private let preferredLanguage: String?

    /// The user's first preferred language, as a bare language code.
    static var defaultPreferredLanguage: String? {
        Locale.preferredLanguages.first.map(languageCode)
    }

    init(
        batchSize: Int = 2000,
        preferredLanguage: String? = XMLTVParser.defaultPreferredLanguage,
        onBatch: @escaping ([ParsedProgramme]) -> Void
    ) {
        self.batchSize = batchSize
        self.preferredLanguage = preferredLanguage.map(Self.languageCode)
        self.onBatch = onBatch
    }

    /// `de-DE`, `de_AT` and `DE` all reduce to `de`.
    static func languageCode(_ tag: String) -> String {
        let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag
        return code.lowercased()
    }

    /// One of a programme's text fields. Multi-language guides repeat
    /// `<title>`, `<sub-title>` and `<desc>` once per language; appending them
    /// ran the translations together ("TagesschauNews"). The first non-empty
    /// value is kept, unless a later one is in the preferred language and the
    /// kept one isn't.
    private struct LocalizedText {
        private(set) var value: String?
        private var isPreferred = false

        mutating func offer(_ text: String, lang: String?, preferred: String?) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let matches = preferred != nil && lang.map(XMLTVParser.languageCode) == preferred
            if value == nil || (matches && !isPreferred) {
                value = text
                isPreferred = matches
            }
        }
    }

    /// Parse an XMLTV file from disk, calling `onBatch` for every `batchSize` programmes.
    /// A malformed or unreadable document is distinct from a well-formed empty
    /// guide: callers must not publish an empty replacement for a parse error.
    static func parse(
        fileURL: URL,
        batchSize: Int = 2000,
        preferredLanguage: String? = XMLTVParser.defaultPreferredLanguage,
        onBatch: @escaping ([ParsedProgramme]) -> Void
    ) -> ParseOutcome {
        guard let xmlParser = XMLParser(contentsOf: fileURL) else {
            return ParseOutcome(programmeCount: 0, encounteredProgrammeCount: 0, succeeded: false)
        }
        let delegate = XMLTVParser(batchSize: batchSize, preferredLanguage: preferredLanguage, onBatch: onBatch)
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
        currentLang = attributeDict["lang"]
        if elementName == "programme" {
            encounteredProgrammeCount += 1
            currentStart = attributeDict["start"]
            currentStop = attributeDict["stop"]
            currentChannel = attributeDict["channel"]
            currentTitle = LocalizedText()
            currentSubtitle = LocalizedText()
            currentDesc = LocalizedText()
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
               let title = currentTitle.value
            {
                batch.append(ParsedProgramme(
                    channelId: channel,
                    title: title,
                    subtitle: currentSubtitle.value,
                    description: currentDesc.value ?? "",
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
            currentTitle = LocalizedText()
            currentSubtitle = LocalizedText()
            currentDesc = LocalizedText()
            currentCategories = []
        } else if elementName == "title" {
            currentTitle.offer(currentText, lang: currentLang, preferred: preferredLanguage)
        } else if elementName == "sub-title" {
            currentSubtitle.offer(currentText, lang: currentLang, preferred: preferredLanguage)
        } else if elementName == "desc" {
            currentDesc.offer(currentText, lang: currentLang, preferred: preferredLanguage)
        } else if elementName == "category" {
            let category = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !category.isEmpty {
                currentCategories.append(category)
            }
        }
    }
}
