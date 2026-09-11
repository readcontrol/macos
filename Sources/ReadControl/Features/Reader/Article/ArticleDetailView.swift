// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ArticleDetailView: View {
    // The reader's loading pipeline lives in `ArticleDetailView+Loading.swift`.
    // Swift's `private` is file-scoped, so the state that pipeline drives — and
    // only that state — is left at the default internal access rather than
    // `private`. Treat it as private to this view and its loading extension;
    // nothing else in the module touches it.
    @Environment(AppState.self) var appState
    @AppStorage("readerFont", store: AppDefaults.store) private var readerFont: ReaderFont = .system
    @AppStorage("readerFontSize", store: AppDefaults.store) private var readerFontSize: ReaderFontSize = .medium
    @AppStorage("readerWidth", store: AppDefaults.store) private var readerWidth: ReaderWidth = .medium
    @AppStorage("readerLineHeight", store: AppDefaults.store) private var readerLineHeight: ReaderLineHeight = .normal

    @State var row: ReadingRow?
    @State var articleDocument: ArticleDocument?
    @State var isLoading = false
    /// True when the selected reading's body is too large to render (see
    /// `maxParseBytes`); drives the oversize notice instead of the reader.
    @State var bodyTooLarge = false

    /// Parsed bodies of readings opened this session, so revisiting one shows
    /// instantly — no re-parse, no spinner (see `ArticleDocumentCache`).
    /// Highlights are deliberately not cached — they're an overlay reloaded on
    /// each open, so toggles made elsewhere still show on return.
    @State var cache = ArticleDocumentCache()

    /// Records where the user stops in the open article, and goes back to that
    /// block when the article opens again (see `ReaderPositionTracker`). The
    /// loading pipeline hands it each document with the stored position.
    @State var positionTracker = ReaderPositionTracker()

    /// Drives the full-screen image-zoom overlay: injected into the reader's
    /// environment so a clicked figure can raise the lightbox, and observed to
    /// present it over the whole detail pane (see `ImageLightbox`) and to drop the
    /// reader's own toolbar actions while it's up (see `toolbarItems`).
    @State private var imageZoom = ImageZoomPresenter()

    /// Bodies larger than this are not parsed at all — swift-markdown would
    /// freeze the main thread and spike memory on a pathological file. The
    /// reader shows an "open in browser" notice instead. ~10 MB is already
    /// ~1.5M words, far beyond any real article.
    let maxParseBytes = 10 * 1024 * 1024
    /// Word-count companion to `maxParseBytes`: a reading this long is treated as
    /// too large *without* fetching its body (see `load`). No real article nears
    /// 1M words, so this short-circuits a pathological body before the reader reads
    /// and marshals megabytes across the FFI.
    let maxParseWords: UInt32 = 1_000_000

    /// Reader typography, derived once from the persisted font settings and shared
    /// by the body (`MarkdownDocumentView`) and the surrounding chrome
    /// (`ArticleHeaderView`, `RatingFooter`) so they all rescale together.
    private var theme: MarkdownTheme {
        MarkdownTheme(font: readerFont, fontSize: readerFontSize,
                      width: readerWidth, lineHeight: readerLineHeight)
    }

    var body: some View {
        @Bindable var appState = appState
        Group {
            if appState.selectedId != nil {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let row {
                    articleView(row: row)
                } else if !isLoading {
                    // selectedId set but row not loaded yet — happens on first render
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyDetail
            }
        }
        // Reader figures raise the full-screen zoom; the lightbox layers over the
        // whole detail pane (see `imageZoomOverlay`). Navigating away dismisses it.
        .imageZoomOverlay(imageZoom)
        // The one trigger for loading: runs on appear *and* on every selection
        // change, and cancels a load still in flight when the selection moves on. A
        // `.task` plus a separate `.onChange` both fired for the same reading, so it
        // was fetched and parsed twice over. Navigating away also closes any open
        // lightbox so it can't linger.
        .task(id: appState.selectedId) {
            imageZoom.dismiss()
            await load(id: appState.selectedId)
        }
        .toolbar { toolbarItems }
        // The lightbox's backdrop is ordinary content, so the titlebar's own
        // material sits above it and leaves a lit band across the top of the zoom.
        // Dropping that material while a zoom is up lets the backdrop — which
        // already ignores the safe area — run the window's full height. The bar
        // itself stays put (search, sort and the sidebar toggle keep working); only
        // its background steps aside, and it returns when the lightbox closes.
        .toolbarBackground(imageZoom.target == nil ? .automatic : .hidden, for: .windowToolbar)
        .inspector(isPresented: $appState.showHighlights) {
            HighlightsInspector(readingId: appState.selectedId)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .sheet(isPresented: $appState.showTagSheet) {
            if let row {
                // Driven by the detail `row`, which add/removeTag update
                // synchronously — so checkmarks flip the instant you toggle.
                TagPickerSheet(
                    applied: row.tags,
                    allTags: appState.sidebar.tags.map(\.tag),
                    onToggle: { tag, shouldApply in
                        if shouldApply {
                            addTag(tag, to: row.id)
                        } else {
                            removeTag(tag, from: row.id)
                        }
                    }
                )
            }
        }
    }

    // ── Article content ───────────────────────────────────────────────────

    private func articleView(row: ReadingRow) -> some View {
        articleContent(row: row)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(row.title.isEmpty ? "Article" : row.title)
    }

    /// The reader: the oversize notice, the parsed document, an excerpt-only
    /// fallback, or nothing. The article header is embedded inside the scroll
    /// area of each branch so it moves with the content.
    @ViewBuilder
    private func articleContent(row: ReadingRow) -> some View {
        if bodyTooLarge {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ArticleHeaderView(row: row, theme: theme)
                    OversizeNotice(url: row.url)
                }
            }
        } else if let articleDocument {
            reader(row: row, document: articleDocument)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Identity tied to the reading so switching articles builds a
                // fresh ScrollView (scrolled to top) instead of inheriting the
                // previous article's offset. Keyed on `row.id` — not the parsed
                // document — so background revalidation of the *same* reading
                // (which can swap in a re-parsed document) doesn't reset scroll.
                .id(row.id)
        } else if let excerpt = row.excerpt, !excerpt.isEmpty {
            excerptFallback(row: row, excerpt: excerpt)
                .id(row.id)
        } else {
            Spacer()
        }
    }

    /// The parsed reader itself, handed the reader's typography (face, size,
    /// measure, and leading) plus the header and rating footer that scroll with it.
    private func reader(row: ReadingRow, document: ArticleDocument) -> some View {
        MarkdownDocumentView(
            document: document,
            assetBaseURL: AssetImageLoader.readingFolderURL(
                libraryURL: appState.libraryURL, readingID: row.id
            ),
            font: readerFont,
            fontSize: readerFontSize,
            width: readerWidth,
            lineHeight: readerLineHeight,
            highlights: appState.highlights.map(\.text),
            onHighlight: { text in
                Task { await appState.toggleHighlight(id: row.id, text: text) }
            },
            onScrollReady: { positionTracker.scrollReady($0) },
            onScrollSettle: { positionTracker.scrollSettled($0) },
            header: { ArticleHeaderView(row: row, theme: theme) },
            footer: { ratingFooter(row: row) }
        )
        // A change of face, size, measure, or leading lays the text out again.
        // Keep the block the reader last saw at the top of the window.
        .onChange(of: typographyKey) { positionTracker.keepAnchor() }
    }

    /// The reader typography, as one value, so a change of any part of it is one
    /// change to watch.
    private var typographyKey: String {
        "\(readerFont.rawValue)|\(readerFontSize.rawValue)|\(readerWidth.rawValue)|\(readerLineHeight.rawValue)"
    }

    /// Excerpt-only fallback when there's no parsed body to show.
    private func excerptFallback(row: ReadingRow, excerpt: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ArticleHeaderView(row: row, theme: theme)
                VStack(alignment: .leading, spacing: 0) {
                    Text(excerpt)
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineSpacing(theme.lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ratingFooter(row: row)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.bottom, 80)
            }
        }
    }

    // ── Rating control ────────────────────────────────────────────────────

    /// End-of-article rating (see `RatingFooter`). The optimistic wiring lives
    /// here because this view owns the detail `row` state: flip the stars now,
    /// then reconcile with the authoritative row once the core write + refresh
    /// land (falling back to the prior row if the write didn't take).
    private func ratingFooter(row: ReadingRow) -> some View {
        RatingFooter(row: row, theme: theme) { newValue in
            let previous = self.row
            var optimistic = row
            optimistic.rating = newValue
            self.row = optimistic
            Task {
                self.row = await appState.setRating(id: row.id, rating: newValue) ?? previous
            }
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView("Select an article to read", systemImage: "doc.text")
            .accessibilityIdentifier(A11y.Detail.empty)
    }

    // ── Toolbar ───────────────────────────────────────────────────────────

    /// The selected row resolved straight from the shared, synchronously
    /// published `appState.readings` (kept fresh by every mutation's refresh).
    /// Driving the toolbar from this — rather than the async-loaded `@State row`
    /// — makes the actions appear/disappear in the SAME render frame as the
    /// sort button (which also keys off `appState.readings`). Using the async
    /// `row` instead lets the two reflow a frame apart, which reads as a blink.
    private var currentRow: ReadingRow? {
        guard let id = appState.selectedId else { return nil }
        // Fall back to the loaded detail row when the selection sits outside the
        // current list — e.g. after re-rating the open article inside a rating
        // filter, where it stays selected and shown but drops off the list. Keeps
        // the toolbar populated instead of blanking the actions for what's on
        // screen.
        return appState.readings.first(where: { $0.id == id }) ?? (row?.id == id ? row : nil)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // The lightbox's backdrop is a content overlay and can't cover the unified
        // title bar, so the reader's own actions step aside while an image is
        // zoomed — they'd float above the dark backdrop and act on an article the
        // user can't see. Only these go: the search field, sort control and sidebar
        // toggle belong to the other columns, which the zoom never covers, so
        // hiding them was gratuitous.
        if let row = currentRow, imageZoom.target == nil {
            ArticleToolbar(row: row, appState: appState)
        }
    }

    // ── Tags ──────────────────────────────────────────────────────────────

    /// Apply a tag to the article: optimistically show the chip now (exact-match
    /// dedup + append mirror the core), then write through and reconcile.
    private func addTag(_ tag: String, to id: String) {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        if var optimistic = row, !optimistic.tags.contains(tag) {
            optimistic.tags.append(tag)
            row = optimistic
        }
        Task {
            await appState.addTag(id: id, tag: tag)
            row = await appState.reloadRow(id: id) ?? row
        }
    }

    /// Remove a tag from the article: optimistically drop the chip, reconcile
    /// after the write.
    private func removeTag(_ tag: String, from id: String) {
        if var optimistic = row {
            optimistic.tags.removeAll { $0 == tag }
            row = optimistic
        }
        Task {
            await appState.removeTag(id: id, tag: tag)
            row = await appState.reloadRow(id: id) ?? row
        }
    }
}
