// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The reader's document-loading pipeline: fetch a body from the core, guard it
/// against pathological sizes, parse it off the main thread, cache it, and show
/// it — plus the background highlight fetch and the revalidation pass that
/// refreshes a cached reading edited on disk.
///
/// Split out of `ArticleDetailView` so neither file runs past the length limit.
/// This is a verbatim move: the ordering and the `selectedId` cancellation
/// guards below are load-bearing (see the comments on each), so nothing here was
/// restructured. The state it drives is declared alongside the view.
extension ArticleDetailView {
    /// The one entry point, driven by the view's `.task(id:)`.
    func load(id: String?) async {
        guard let id else {
            row = nil
            articleDocument = nil
            bodyTooLarge = false
            await appState.loadHighlights(id: nil)
            return
        }
        // Debounce every selection change so a fast run of ↑/↓ — cancelled per step
        // by `.task(id:)` — does no work for a reading skimmed past: no fetch, no
        // parse, and no main-thread rebuild of the reader tree, which swapping in even
        // a cached document costs and is what made navigating opened readings stutter.
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }

        row = appState.readings.first(where: { $0.id == id })

        // Short-circuit a pathological body straight to the oversize notice from the
        // cheap indexed word count — before fetching and parsing megabytes of text,
        // the very cost this guard exists to avoid. `present`'s exact byte check
        // still backstops a missing word count.
        if let words = row?.wordCount, words > maxParseWords {
            articleDocument = nil
            bodyTooLarge = true
            isLoading = false
            return
        }

        // Revisiting an already-opened reading: show its parsed body straight from
        // the cache — no re-parse, no spinner — then revalidate just this reading
        // below. Highlights are reloaded so toggles made elsewhere show.
        if let cached = cache.lookup(id) {
            articleDocument = cached.document
            bodyTooLarge = false
            isLoading = false
            loadHighlightsInBackground(id: id)
            await startTracking(id: id, document: cached.document)
            await revalidate(id: id, cachedBody: cached.body)
            return
        }

        await loadUncached(id: id)
    }

    /// The cache-miss tail: fetch the body from the core, then parse it off the main
    /// thread (see `ArticleDocument.parse`). Reached only past `load`'s debounce, so a
    /// reading skimmed past never gets here.
    private func loadUncached(id: String) async {
        isLoading = true
        loadHighlightsInBackground(id: id)
        // The native reader parses Markdown directly (linked images like
        // `[![alt](img)](url)` are handled by the renderer), so no HTML
        // conversion or asset-path rewriting is needed. Parse here, off the
        // per-render path, so re-rendering the reader never re-parses.
        let body = await appState.getBody(id: id)
        // A load can be superseded while the body is in flight: `.task(id:)` cancels
        // us, but neither the fetch above nor the detached parse in `present` observes
        // that cancellation. Bail before touching shared reader state so a stale load
        // can't paint over — or clear the spinner of — the reading now loading.
        guard appState.selectedId == id else { return }
        await present(body: body, id: id)
        guard appState.selectedId == id else { return }
        isLoading = false
    }

    /// Show a freshly fetched body: parse, cache, and display it — unless it
    /// exceeds `maxParseBytes`, in which case skip parsing entirely and flag it
    /// so the reader shows the oversize notice. The parse runs off the main
    /// thread (see `ArticleDocument.parse`), so a large article can't stall the
    /// UI. A nil body (nothing fetched) clears the reader.
    private func present(body: String?, id: String) async {
        guard let body else {
            articleDocument = nil
            bodyTooLarge = false
            return
        }
        guard body.utf8.count <= maxParseBytes else {
            // Too large to render: don't parse, and don't keep any stale cache.
            cache.remove(id)
            articleDocument = nil
            bodyTooLarge = true
            return
        }
        bodyTooLarge = false
        let document = await ArticleDocument.parse(markdown: body)
        // Cache the finished parse under its own id even if the selection moved on
        // while it ran — the work is done and keyed by `id`, so revisiting hits the
        // cache instead of re-parsing.
        cache.store(body: body, document: document, for: id)
        // A detached parse can outlive the selection that asked for it — don't paint
        // it over the reading now on screen if the user moved on.
        guard appState.selectedId == id else { return }
        articleDocument = document
        await startTracking(id: id, document: document)
    }

    /// Give the position tracker the article the reader now shows, with the
    /// position the core stored for it. The tracker goes to that block, and from
    /// then on it records the block at the top of the window.
    ///
    /// The fetch of the position is one small file read, and it runs after the
    /// article is on screen, so it never holds the reader back.
    private func startTracking(id: String, document: ArticleDocument) async {
        positionTracker.onRecord = { readingID, anchor in
            Task {
                await appState.recordPosition(id: readingID, block: anchor.block,
                                              quote: anchor.quote, percent: anchor.percent)
            }
        }
        let position = await appState.position(id: id)
        guard appState.selectedId == id else { return }
        positionTracker.open(readingID: id, document: document, position: position)
    }

    /// Fetch the reading's highlights *off* the reader's critical path.
    ///
    /// Highlights are a tint applied over already-rendered text, so nothing about
    /// showing the article depends on them — yet this was awaited *before* the body
    /// was even fetched, gating the whole reader on it. Firing it as a detached task
    /// lets the article render immediately; `appState.highlights` is observed, so the
    /// tint applies on the next render once it lands.
    private func loadHighlightsInBackground(id: String) {
        Task { await appState.loadHighlights(id: id) }
    }

    /// After showing a reading from cache, re-read its body and re-parse only if
    /// it changed on disk — so an external edit to a single file refreshes just
    /// that reading, leaving every other cached reading intact. Cheap when
    /// nothing changed (a body fetch + string compare), and off the critical
    /// path since the cached parse is already on screen.
    private func revalidate(id: String, cachedBody: String) async {
        let body = await appState.getBody(id: id)
        // Bail if the user moved on, or nothing changed.
        guard appState.selectedId == id, let body, body != cachedBody else { return }
        await present(body: body, id: id)
    }
}
