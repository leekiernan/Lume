//
//  CustomHomeSectionEditor.swift
//  Lume
//
//  Add / edit sheet for a custom Home row (iOS, macOS). The user gives a
//  header and a list URL; saving verifies the URL actually resolves to a list
//  before it's stored, so a typo is caught here rather than showing up as a row
//  that silently never appears on Home.
//

#if !os(tvOS)

    import SwiftUI

    struct CustomHomeSectionEditor: View {
        /// Adding a new row, or editing one that already exists.
        enum Mode: Identifiable {
            case add
            case edit(CustomHomeSection)

            var id: String {
                switch self {
                case .add: "add"
                case let .edit(section): section.id.uuidString
                }
            }

            var existing: CustomHomeSection? {
                if case let .edit(section) = self { return section }
                return nil
            }
        }

        let mode: Mode
        let onSave: (CustomHomeSection) -> Void
        let onDelete: (UUID) -> Void

        @Environment(\.dismiss) private var dismiss
        @State private var title = ""
        @State private var urlText = ""
        @State private var state = CheckState.idle
        @State private var showingDeleteConfirmation = false

        /// Where the sheet is in its verify-then-save cycle. `failed` keeps the
        /// sheet open with the provider's own message.
        private enum CheckState: Equatable {
            case idle
            case checking
            case failed(String)

            var message: String? {
                if case let .failed(message) = self { return message }
                return nil
            }
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("Title", text: $title, prompt: titlePrompt)
                        TextField("List URL", text: $urlText, prompt: Text(verbatim: exampleURL))
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                    } header: {
                        Text("Section")
                    } footer: {
                        footer
                    }

                    if let message = state.message {
                        Section {
                            Label {
                                Text(verbatim: message)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .font(.footnote)
                        }
                    }

                    if mode.existing != nil {
                        Section {
                            Button("Remove Section", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                        }
                    }
                }
                #if os(macOS)
                .formStyle(.grouped)
                .frame(minWidth: 460, minHeight: 320)
                #endif
                .platformNavigationTitle(mode.existing == nil ? "Add Section" : "Edit Section")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            if state == .checking {
                                ProgressView()
                            } else {
                                Button("Save") { save() }
                                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                    .confirmationDialog(
                        "Remove Section",
                        isPresented: $showingDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Remove", role: .destructive) {
                            if let existing = mode.existing { onDelete(existing.id) }
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes the row from Home. Nothing in your library changes.")
                    }
                    .onAppear(perform: prefill)
            }
        }

        // MARK: - Content

        private var footer: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste the address of a public list. Lume matches the titles on it against your playlist and shows the ones you have.")
                Text("Supported: \(supportedProviders).")
            }
        }

        private var supportedProviders: String {
            HomeListCatalog.providers.map(\.displayName).formatted(.list(type: .and))
        }

        private var exampleURL: String {
            HomeListCatalog.providers.first?.exampleURL ?? ""
        }

        /// The header suggested from the URL, shown as the title field's prompt
        /// so the user can leave it blank and take it.
        private var suggestedTitle: String? {
            HomeListCatalog.suggestedTitle(for: urlText)
        }

        private var titlePrompt: Text {
            if let suggestedTitle {
                return Text(verbatim: suggestedTitle)
            }
            return Text("Section title")
        }

        private func prefill() {
            guard let existing = mode.existing, title.isEmpty, urlText.isEmpty else { return }
            title = existing.title
            urlText = existing.sourceURL
        }

        // MARK: - Save

        /// Verifies the list resolves before storing it. A section that can't be
        /// read would otherwise just never appear on Home, with nothing to say why.
        private func save() {
            let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = typed.isEmpty ? (suggestedTitle ?? "") : typed
            guard !resolvedTitle.isEmpty else {
                state = .failed(String(localized: "Give the section a title."))
                return
            }
            state = .checking
            Task {
                do {
                    _ = try await HomeListCatalog.entries(for: url)
                } catch {
                    let message = (error as? HomeListError)?.errorDescription ?? error.localizedDescription
                    state = .failed(message)
                    return
                }
                onSave(CustomHomeSection(
                    id: mode.existing?.id ?? UUID(),
                    title: resolvedTitle,
                    sourceURL: url
                ))
                dismiss()
            }
        }
    }

#endif
