//
//  CachedAsyncImage.swift
//  Lume
//
//  A drop-in replacement for SwiftUI's `AsyncImage` that fixes the reliability
//  problems that make posters and backdrops fail to load:
//
//  • Memory + disk caching (see `ImagePipeline`), so images survive cell reuse
//    and app launches instead of re-downloading and flashing placeholders.
//  • Automatic retry on transient network failures, and a short freeze-out for
//    URLs that just failed so a dead poster isn't re-requested on every pass.
//  • Optional downsampling via `maxPixelSize` (longest edge in points; converted
//    to pixels using the display scale) to cut memory and decode time for cards.
//    Pass `nil` for full-resolution artwork such as tvOS 4K heroes.
//  • Fades in artwork that had to be fetched, while keeping cache hits instant.
//    Pass an explicit `transaction` to override, or `Transaction()` to disable.
//
//  The closure API mirrors `AsyncImage` — it hands back an `AsyncImagePhase`
//  (`.empty` / `.success` / `.failure`) — so migrating a call site is usually
//  just renaming `AsyncImage` to `CachedAsyncImage`.
//

import SwiftUI

struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    /// Longest edge to decode to, in points. `nil` keeps full resolution.
    private let maxPixelSize: CGFloat?
    private let transaction: Transaction
    private let content: (AsyncImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: AsyncImagePhase = .empty
    /// The request that produced `phase`. SwiftUI can preserve this view's state
    /// while changing its URL, so an unkeyed success would draw the previous
    /// image for one frame before the new `.task` resets it.
    @State private var phaseTaskID: String?

    /// Fades artwork in once it arrives from the network so posters don't hard-cut
    /// from placeholder to image. Memory-cache hits are rendered directly by
    /// `body`, outside the transaction, so they still appear instantly.
    static var defaultTransaction: Transaction {
        Transaction(animation: .easeIn(duration: 0.2))
    }

    init(
        url: URL?,
        maxPixelSize: CGFloat? = nil,
        transaction: Transaction? = nil,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.transaction = transaction ?? Self.defaultTransaction
        self.content = content
    }

    var body: some View {
        // Resolve decoded-memory hits while building the view. Waiting for the
        // `.task` below gives even a cache hit one placeholder frame first, which
        // is especially visible as a black flash across a full-screen hero.
        content(renderPhase)
            .task(id: taskID) { await load() }
    }

    private var renderPhase: AsyncImagePhase {
        guard let url else { return .failure(URLError(.badURL)) }
        if let cached = ImagePipeline.cachedImage(for: url, maxPixelSize: pixelSize) {
            return .success(Image(platformImage: cached))
        }
        // Never reuse a prior URL's phase while SwiftUI is waiting to start the
        // new keyed task. A disk-only hit remains empty until its off-main-thread
        // read and decode completes.
        return phaseTaskID == taskID ? phase : .empty
    }

    /// Restart the load whenever the URL or target size changes (e.g. cell reuse).
    private var taskID: String {
        guard let url else { return "nil" }
        return ImagePipeline.memoryKey(url, maxPixelSize: pixelSize)
    }

    /// Target size in pixels, or `nil` for full resolution.
    private var pixelSize: CGFloat? {
        guard let maxPixelSize else { return nil }
        return maxPixelSize * displayScale
    }

    private func load() async {
        let requestID = taskID
        guard let url else {
            phaseTaskID = requestID
            phase = .failure(URLError(.badURL))
            return
        }

        // The body has already rendered a memory-cache hit synchronously. Keep
        // it in state too, so an unrelated cache eviction does not blank a live
        // view on its next update.
        if let cached = ImagePipeline.cachedImage(for: url, maxPixelSize: pixelSize) {
            phaseTaskID = requestID
            phase = .success(Image(platformImage: cached))
            return
        }

        phaseTaskID = requestID
        phase = .empty

        do {
            let image = try await ImagePipeline.shared.image(for: url, maxPixelSize: pixelSize)
            guard !Task.isCancelled, taskID == requestID else { return }
            withTransaction(transaction) {
                phase = .success(Image(platformImage: image))
            }
        } catch {
            // The cell scrolled away mid-load: the shared fetch is now cancelled
            // with us (see `ImagePipeline`) so the posters still on screen aren't
            // stuck behind it. Leave the phase alone — this view is going away, and
            // a stored .failure would show the broken-artwork placeholder for a
            // beat if it comes back. `URLSession` reports a cancelled request as
            // `URLError.cancelled` rather than `CancellationError`, hence the helper.
            guard !ImagePipeline.isCancellation(error), taskID == requestID else { return }
            withTransaction(transaction) {
                phase = .failure(error)
            }
        }
    }
}
