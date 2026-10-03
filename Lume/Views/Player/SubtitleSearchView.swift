//
//  SubtitleSearchView.swift
//  Lume
//
//  In-player OpenSubtitles browser: searches for subtitle tracks matching the
//  title on screen, downloads the one the viewer picks, and hands the local file
//  back for the active engine to side-load.
//
//  Presented from the engine views rather than from the controls overlay, since
//  the overlay is torn down when the controls auto-hide — a sheet anchored there
//  would vanish with it. See `subtitleSearch(isPresented:media:onPick:)`.
//
//  The search itself is shared, the layout is not: iOS/macOS get a `List`, while
//  tvOS gets a ten-foot layout built from the app's TV components (see
//  `SubtitleSearchView+TV.swift`). A `List` at iOS metrics is unreadable across a
//  room and sits flush against the overscan margin.
//

import SwiftData
import SwiftUI

struct SubtitleSearchView: View {
    let media: PlayableMedia
    /// Handed the downloaded file; the caller loads it into its engine and the
    /// sheet dismisses itself.
    var onPick: (ExternalSubtitle) -> Void

    @Environment(\.modelContext) private var modelContext
    /// Not `private`: the tvOS layout lives in an extension in its own file.
    @Environment(\.dismiss) var dismiss

    @State var service = OpenSubtitlesService.shared
    @State private var machine = SubtitleSearchMachine()
    @State private var downloadTask: Task<Void, Never>?

    private struct SearchKey: Equatable {
        let mediaID: String
        let languages: [String]
    }

    var body: some View {
        Group {
            #if os(tvOS)
                tvBody
            #else
                standardBody
            #endif
        }
        .task(id: SearchKey(mediaID: media.id, languages: service.preferredLanguages)) { await runSearch() }
        .onDisappear {
            machine.invalidate()
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    // MARK: - Shared state

    var status: SubtitleSearchStatus {
        machine.status
    }

    var results: [OnlineSubtitle] {
        machine.results
    }

    var downloadingID: String? {
        machine.downloadingID
    }

    var isSearching: Bool {
        machine.isSearching
    }

    var downloadError: String? {
        machine.downloadError
    }

    var languageSummary: String {
        let names = service.preferredLanguages.map { TrackLanguageMatcher.displayName(for: $0) }
        return names.isEmpty ? String(localized: "Any") : names.joined(separator: ", ")
    }

    // MARK: - Actions

    func runSearch() async {
        // Resolving the ids touches SwiftData on the main actor; the fetch that
        // follows is off it.
        let resolved = SubtitleSearchQuery.resolve(for: media.contentRef, in: modelContext)
        let request = machine.begin(mediaID: media.id, supported: resolved != nil)
        guard let resolved else { return }
        do {
            let results = try await service.search(resolved)
            guard !Task.isCancelled else { return }
            machine.finish(request, results: results)
        } catch let error as OpenSubtitlesError {
            guard !Task.isCancelled else { return }
            machine.fail(request, message: String(localized: error.message))
        } catch {
            guard !Task.isCancelled else { return }
            machine.fail(request, message: error.localizedDescription)
        }
    }

    func pick(_ subtitle: OnlineSubtitle) {
        guard let request = machine.beginDownload(subtitle) else { return }
        downloadTask = Task {
            do {
                let fileURL = try await service.download(subtitle)
                guard !Task.isCancelled, machine.finishDownload(request) else { return }
                onPick(ExternalSubtitle(
                    id: subtitle.id,
                    label: "\(subtitle.languageName) · OpenSubtitles",
                    fileURL: fileURL
                ))
                dismiss()
            } catch let error as OpenSubtitlesError {
                guard !Task.isCancelled else { return }
                machine.finishDownload(request, error: String(localized: error.message))
            } catch {
                guard !Task.isCancelled else { return }
                machine.finishDownload(request, error: error.localizedDescription)
            }
        }
    }

    // MARK: - iOS / macOS / visionOS

    #if !os(tvOS)
        private var standardBody: some View {
            NavigationStack {
                List {
                    if !service.isSignedIn {
                        OpenSubtitlesSignInSection()
                    }
                    languageSection
                    resultsSection
                }
                .platformNavigationTitle("Subtitles")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        private var languageSection: some View {
            Section {
                NavigationLink {
                    SubtitleLanguagePicker()
                } label: {
                    HStack {
                        Label("Languages", systemImage: "globe")
                        Spacer()
                        Text(languageSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }

        private var resultsSection: some View {
            Section {
                if isSearching, !results.isEmpty {
                    ProgressView("Searching…")
                }
                if let downloadError {
                    Text(downloadError).foregroundStyle(.red)
                }
                switch status {
                case .searching:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                case let .failed(message):
                    Text(message)
                        .foregroundStyle(.red)
                case .unsupported:
                    Text("Subtitle search is only available for movies and episodes.")
                        .foregroundStyle(.secondary)
                case .empty:
                    Text("No subtitles found for this title.")
                        .foregroundStyle(.secondary)
                case .results:
                    ForEach(results) { subtitle in
                        Button {
                            pick(subtitle)
                        } label: {
                            SubtitleResultRow(
                                subtitle: subtitle,
                                isDownloading: downloadingID == subtitle.id
                            )
                        }
                        // Without this the whole row inherits the tint and every
                        // line renders blue, including the release name and count.
                        .buttonStyle(.plain)
                        .disabled(downloadingID != nil)
                    }
                }
            } header: {
                Text(media.title)
            } footer: {
                if let remaining = service.remainingDownloads {
                    Text("\(remaining) downloads left today.")
                }
            }
        }
    #endif
}

// MARK: - Result row (iOS / macOS / visionOS)

#if !os(tvOS)
    private struct SubtitleResultRow: View {
        let subtitle: OnlineSubtitle
        let isDownloading: Bool

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(subtitle.languageName)
                            .font(.headline)
                        ForEach(subtitle.badges) { badge in
                            Image(systemName: badge.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !subtitle.releaseName.isEmpty {
                        Text(subtitle.releaseName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("\(subtitle.downloadCount) downloads")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if isDownloading {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
    }
#endif

// MARK: - Language picker

/// Multi-select over the languages OpenSubtitles indexes. Writes straight
/// through to `OpenSubtitlesService.preferredLanguages`, which persists the
/// choice and re-runs the search.
struct SubtitleLanguagePicker: View {
    // Not `private`: the tvOS layout lives in an extension in its own file.
    @State var service = OpenSubtitlesService.shared
    @State var languages: [OpenSubtitlesLanguage] = []
    @State var searchText = ""

    var body: some View {
        Group {
            #if os(tvOS)
                tvBody
            #else
                standardBody
            #endif
        }
        .task { languages = await service.languages() }
    }

    var filtered: [OpenSubtitlesLanguage] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return languages }
        return languages.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Keeps at least one language selected — an empty list would ask the API
    /// for every language there is.
    func toggle(_ code: String) {
        var selection = service.preferredLanguages
        if let index = selection.firstIndex(of: code) {
            guard selection.count > 1 else { return }
            selection.remove(at: index)
        } else {
            selection.append(code)
        }
        service.preferredLanguages = selection
    }

    #if !os(tvOS)
        private var standardBody: some View {
            List {
                ForEach(filtered) { language in
                    Button {
                        toggle(language.code)
                    } label: {
                        HStack {
                            Text(language.name)
                            Spacer()
                            if service.preferredLanguages.contains(language.code) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .platformNavigationTitle("Languages")
            .searchable(text: $searchText, prompt: Text("Search languages"))
        }
    #endif
}

// MARK: - Presentation

extension View {
    /// Presents the OpenSubtitles browser for `media`. Applied by the engine
    /// views (not their controls overlays) so the sheet outlives the controls
    /// auto-hiding underneath it.
    func subtitleSearch(
        isPresented: Binding<Bool>,
        media: PlayableMedia,
        onPick: @escaping (ExternalSubtitle) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            SubtitleSearchView(media: media, onPick: onPick)
                // The player forces dark; a sheet raised from it inherits the
                // app appearance otherwise and flashes light over the video.
                .preferredColorScheme(.dark)
            #if os(macOS)
                // A macOS sheet is sized by its content, and a `List` has no
                // ideal height to offer — without a frame the browser opened as
                // a bare toolbar with the results collapsed to nothing, which
                // reads as "no subtitles found".
                .frame(minWidth: 460, idealWidth: 540, minHeight: 480, idealHeight: 600)
            #endif
        }
    }
}
