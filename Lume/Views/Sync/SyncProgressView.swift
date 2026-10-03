//
//  SyncProgressView.swift
//  Lume
//
//  Shared progress UI for automatic and manual ContentSyncManager runs.
//

import SwiftData
import SwiftUI

struct SyncProgressView: View {
    let playlist: Playlist

    /// Auto-sync begins on appearance; manual sync waits for Start.
    let autoStart: Bool

    /// Only Stalker honours this full-catalog option; other source types ignore it.
    let full: Bool

    /// Non-nil only for automatic repair after a profile enables missing phases.
    let repairingAreas: Set<AppArea>?

    /// Captured once when this presentation is created. The actual sync receives
    /// this same snapshot, so changing profile preferences elsewhere cannot make
    /// the progress list disagree with the work already confirmed here.
    let plan: PlaylistSyncPlan

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var progress = SyncProgress()
    @State private var phase: Phase
    @State private var syncError: String?
    @State private var syncTask: Task<Void, Never>?
    /// The guide refresh that follows the sync, which the screen reports and
    /// never waits for (`SyncGuideStatus`).
    @State private var epg = EPGSyncService.shared
    @State private var finishedAt: Date?
    @State private var sawGuideRunning = false

    init(
        playlist: Playlist,
        autoStart: Bool = false,
        full: Bool = false,
        repairingAreas: Set<AppArea>? = nil
    ) {
        self.playlist = playlist
        self.autoStart = autoStart
        self.full = full
        self.repairingAreas = repairingAreas
        plan = PlaylistSyncPlan(
            sourceType: playlist.sourceType,
            full: full,
            repairingAreas: repairingAreas
        )
        _progress = State(initialValue: SyncProgress(
            steps: plan.steps
        ))
        // Start already in the syncing state for auto-sync so the "Ready" screen
        // (with its Start button) never flashes before `.task` kicks off.
        _phase = State(initialValue: autoStart ? .syncing : .ready)
    }

    private enum Phase {
        case ready
        case syncing
        case finished
        case failed
    }

    var body: some View {
        Group {
            #if os(tvOS)
                tvBody
            #else
                standardBody
            #endif
        }
        .retryingSync(of: playlist.id, failed: phase == .failed, retry: startSync)
        .onChange(of: epg.isSyncing) { _, running in
            if running, finishedAt != nil { sawGuideRunning = true }
        }
    }

    /// Where the post-sync guide refresh is; shown only when the sync brings
    /// in Live TV, which is what owes one.
    private var guideStatus: SyncGuideStatus? {
        guard plan.refreshesGuide else { return nil }
        return SyncGuideStatus.status(
            syncFinished: phase == .finished,
            syncFailed: phase == .failed,
            guideRunning: epg.isSyncing,
            sawGuideRunning: sawGuideRunning,
            guideUpdatedSinceSync: finishedAt.map { (EPGSyncSchedule.lastSyncDate ?? .distantPast) > $0 } ?? false
        )
    }

    // MARK: - Shared header content

    private var headerIcon: String {
        switch phase {
        case .ready: "arrow.triangle.2.circlepath"
        case .syncing: "arrow.triangle.2.circlepath"
        case .finished: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var headerTint: Color {
        switch phase {
        case .ready, .syncing: .lumeAccent
        case .finished: .green
        case .failed: .red
        }
    }

    private var headerTitle: LocalizedStringKey {
        switch phase {
        case .ready: "Ready to sync"
        case .syncing: "Syncing your playlist"
        case .finished: "Sync complete"
        case .failed: "Sync failed"
        }
    }

    // MARK: - Drive sync

    private func startSync() {
        // Fresh progress for each attempt so a retry starts clean.
        progress = SyncProgress(steps: plan.steps)
        syncError = nil
        phase = .syncing

        syncTask = Task {
            do {
                try await PlaylistSyncRun.perform(
                    playlist,
                    container: modelContext.container,
                    plan: plan,
                    progress: progress
                )
                await MainActor.run {
                    if !autoStart {
                        PlaylistSyncCoverage.deferAutomaticRepair(
                            plan.skippedForProfile,
                            playlistID: playlist.id
                        )
                    }
                    finishedAt = Date()
                    sawGuideRunning = epg.isSyncing
                    phase = .finished
                    // Auto-sync gets out of the way as soon as it succeeds so the
                    // user can start browsing; the manual flow waits for Done.
                    if autoStart { dismiss() }
                }
            } catch is CancellationError {
                // User aborted — the sheet is being dismissed, nothing to show.
            } catch {
                // A cancelled network request surfaces as a non-CancellationError;
                // swallow it too so an abort never flashes the failure screen.
                if Task.isCancelled { return }
                await MainActor.run {
                    syncError = error.localizedDescription
                    phase = .failed
                }
            }
        }
    }

    /// Cancels the in-flight sync (if any) and closes the sheet. Cancellation
    /// propagates into ContentSyncManager, which restores the playlist to idle.
    private func abortSync() {
        syncTask?.cancel()
        syncTask = nil
        dismiss()
    }
}

// MARK: - iOS / macOS layout

#if !os(tvOS)

    private extension SyncProgressView {
        var standardBody: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    header

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if phase == .ready { SyncPlanSummary(plan: plan) }

                            ForEach(progress.steps) { step in
                                StepRowView(
                                    step: step,
                                    state: progress.state(for: step),
                                    detail: progress.currentStep == step ? progress.stepDetail : "",
                                    fraction: progress.currentStep == step ? progress.stepFraction : 0
                                )
                            }
                            if let guideStatus { SyncGuideRow(status: guideStatus) }
                        }
                        .padding()
                    }

                    Divider()

                    footer
                        .padding()
                }
                .navigationTitle("Sync Playlist")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                // While syncing, Cancel aborts the in-flight work;
                                // otherwise it just closes the sheet.
                                if phase == .syncing {
                                    abortSync()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
            }
            .interactiveDismissDisabled(phase == .syncing)
            .task {
                if autoStart, phase != .finished {
                    startSync()
                }
            }
        }

        // MARK: Header

        var header: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: headerIcon)
                        .font(.title2)
                        .foregroundStyle(headerTint)
                        .symbolEffect(.pulse, options: .repeating, isActive: phase == .syncing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(headerTitle)
                            .font(.headline)
                        Text(playlist.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if phase == .syncing || phase == .finished {
                    ProgressView(value: progress.overallFraction)
                        .progressViewStyle(.linear)
                        .tint(.lumeAccent)
                }
            }
            .padding()
        }

        // MARK: Footer

        @ViewBuilder
        var footer: some View {
            switch phase {
            case .ready:
                Button {
                    startSync()
                } label: {
                    Label("Start Sync", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .syncing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("This may take a few minutes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

            case .finished:
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .failed:
                VStack(spacing: 12) {
                    if let syncError {
                        Text(syncError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        startSync()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // Let the user leave a failed auto-sync without retrying — they
                    // can sync later from the playlist's settings.
                    Button("Continue Without Syncing") {
                        dismiss()
                    }
                    .controlSize(.large)
                }
            }
        }
    }

#endif

// MARK: - tvOS layout

#if os(tvOS)

    private extension SyncProgressView {
        /// Full-screen, focusable layout sharing the flat dark fill used by the
        /// rest of the tvOS settings surfaces. Vertically centered — the eight
        /// steps plus header and footer comfortably fit a 1080p screen.
        var tvBody: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 48) {
                    tvHeader
                    tvSteps
                    tvFooter
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, 80)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tvSettingsBackground()
            .interactiveDismissDisabled(phase == .syncing)
            .task {
                if autoStart, phase != .finished {
                    startSync()
                }
            }
        }

        // MARK: Header

        var tvHeader: some View {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    Image(systemName: headerIcon)
                        .font(.system(size: 56))
                        .foregroundStyle(headerTint)
                        .symbolEffect(.pulse, options: .repeating, isActive: phase == .syncing)
                        .frame(width: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(headerTitle)
                            .font(.system(size: 44, weight: .bold))
                        Text(verbatim: playlist.name)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                if phase == .syncing || phase == .finished {
                    ProgressView(value: progress.overallFraction)
                        .progressViewStyle(.linear)
                        .tint(.white)
                }
            }
        }

        // MARK: Steps

        var tvSteps: some View {
            VStack(alignment: .leading, spacing: 6) {
                if phase == .ready { SyncPlanSummary(plan: plan, large: true) }
                ForEach(progress.steps) { step in
                    TVStepRow(
                        step: step,
                        state: progress.state(for: step),
                        detail: progress.currentStep == step ? progress.stepDetail : "",
                        fraction: progress.currentStep == step ? progress.stepFraction : 0
                    )
                }
                if let guideStatus { TVSyncGuideRow(status: guideStatus) }
            }
        }

        // MARK: Footer

        @ViewBuilder
        var tvFooter: some View {
            switch phase {
            case .ready:
                HStack(spacing: 24) {
                    Button {
                        startSync()
                    } label: {
                        Label("Start Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))

                    Button("Cancel") { dismiss() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .center)

            case .syncing:
                VStack(spacing: 32) {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("This may take a few minutes…")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }

                    Button("Cancel") { abortSync() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .center)

            case .finished:
                Button("Done") { dismiss() }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                    .frame(maxWidth: .infinity, alignment: .center)

            case .failed:
                VStack(spacing: 24) {
                    if let syncError {
                        Text(verbatim: syncError)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 640)
                    }

                    HStack(spacing: 24) {
                        Button {
                            startSync()
                        } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: true))

                        Button("Continue Without Syncing") { dismiss() }
                            .buttonStyle(TVSettingsActionButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - tvOS Step Row

#endif
