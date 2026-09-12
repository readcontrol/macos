// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ReadingListView: View {
    @Environment(AppState.self) private var appState

    /// Shared with the sidebar so ← can hand focus back across to it.
    @FocusState.Binding var focusedColumn: FocusColumn?

    /// The column's current width, measured by `ContentView`. The toolbar's search
    /// field is sized from it so it grows with the column instead of overflowing a
    /// narrow one.
    let columnWidth: Double

    var body: some View {
        Group {
            if appState.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.readings.isEmpty {
                // Skip the empty state in focus mode: the column collapses to zero
                // width there, and `ContentUnavailableView`'s centered layout can't
                // resolve at ~0pt — it loops constraint updates until AppKit crashes
                // the window ("Update Constraints in Window"). A `List` clips fine,
                // so this guard is only needed for the empty state.
                if !appState.isFocusMode {
                    emptyState
                }
            } else {
                list
            }
        }
        // Present in every state (including the empty list) so a count of 0 is
        // still readable.
        .background { rowsProbe }
        // No `.navigationTitle` here on purpose — the column shows no header. The
        // titlebar draws no title at all either (see the window toolbar style in
        // `ReadControlApp`), so nothing falls back to the app name.
        .onChange(of: appState.searchQuery) { _, _ in
            appState.searchDidChange()
        }
        .task { await appState.loadReadings() }
        .onChange(of: appState.sortField) { _, _ in
            Task { await appState.loadReadings() }
        }
        .onChange(of: appState.searchSort) { _, _ in
            Task { await appState.loadReadings() }
        }
        .onChange(of: appState.sortAscending) { _, _ in
            Task { await appState.loadReadings() }
        }
        .toolbar { toolbarItems }
        .confirmationDialog(
            "Delete this reading?",
            isPresented: Binding(
                get: { appState.pendingDelete != nil },
                set: {
                    if !$0 {
                        appState.pendingDelete = nil
                    }
                }
            ),
            presenting: appState.pendingDelete
        ) { row in
            Button("Delete", role: .destructive) {
                Task { await appState.delete(row) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("“\(row.title.isEmpty ? row.url : row.title)” will be permanently removed "
                + "from your library, including its files. This cannot be undone.")
        }
    }

    // ── Rows probe ──────────────────────────────────────────────────────────

    /// An invisible element describing the loaded rows to the UI-test suite: its
    /// accessibility **label** is the row count and its **value** is the ordered
    /// row ids (comma-joined), both read via a single `firstMatch` (see
    /// `ReadingListPage.waitForRowCount` / `orderedRowIds`). Enumerating the row
    /// elements to count or order them trips an XCUITest snapshot bug that fails on
    /// any article heading in the reader; this one element sidesteps it.
    ///
    /// Hidden with a *clear foreground*, not `.opacity(0)`: a fully-transparent
    /// view is dropped from the accessibility tree (so `exists` is false), whereas
    /// a clear tint keeps the element queryable while leaving nothing on screen.
    /// The label is the always-non-empty count ("0" for an empty list) so the
    /// element is never pruned as empty; the value carries the ids.
    private var rowsProbe: some View {
        let ids = appState.readings.map(\.id)
        return Text(verbatim: "\(ids.count)")
            .foregroundStyle(.clear)
            .accessibilityIdentifier(A11y.List.rows)
            .accessibilityValue(ids.joined(separator: ","))
    }

    // ── List ──────────────────────────────────────────────────────────────

    /// List selection that refuses to clear when the user clicks empty space.
    /// Keeping a row selected keeps the selection-dependent toolbar (sort +
    /// actions) stable. The selection is still cleared for an empty list — that
    /// path goes through `loadReadings()`, not this binding.
    private var listSelection: Binding<String?> {
        Binding(
            get: { appState.selectedId },
            set: { newValue in
                if newValue != nil {
                    appState.selectedId = newValue
                }
            }
        )
    }

    private var list: some View {
        List(appState.readings, id: \.id, selection: listSelection) { row in
            ReadingRowView(row: row)
                .tag(row.id)
                .accessibilityIdentifier(A11y.List.row(row.id))
                .contextMenu { contextMenu(for: row) }
                .onAppear {
                    if row.id == appState.readings.last?.id {
                        Task { await appState.loadMoreReadings() }
                    }
                }
        }
        .listStyle(.inset)
        .accessibilityIdentifier(A11y.List.table)
        .focused($focusedColumn, equals: .list)
        // ← hands focus back to the sidebar; ↑/↓ keep moving through the
        // readings. (→ into the reader isn't part of the arrow cycle.)
        .onKeyPress(.leftArrow) {
            focusedColumn = .sidebar
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if appState.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.background)
            }
        }
    }

    // ── Empty state ───────────────────────────────────────────────────────

    @ViewBuilder
    private var emptyState: some View {
        if !appState.searchQuery.isEmpty {
            // System-provided, auto-localized "No Results for …" state.
            ContentUnavailableView.search(text: appState.searchQuery)
                .accessibilityIdentifier(A11y.List.searchEmptyState)
        } else if appState.selectedTag != nil {
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "tray")
            } actions: {
                // Clears the tag; any view/rating filters stay put (they compose).
                Button("Clear tag filter") {
                    Task { await appState.clearTag() }
                }
                .accessibilityIdentifier(A11y.List.clearTagFilter)
            }
            .accessibilityIdentifier(A11y.List.tagEmptyState)
        } else if appState.selectedRating != nil {
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "tray")
            } actions: {
                // Clears the rating; the view filter stays put (they compose).
                Button("Clear rating filter") {
                    appState.toggleRating(appState.selectedRating!)
                }
            }
            .accessibilityIdentifier(A11y.List.emptyState)
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "tray")
                .accessibilityIdentifier(A11y.List.emptyState)
        }
    }

    // ── Toolbar ───────────────────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        @Bindable var appState = appState
        // Search + sort own the list column's toolbar section — there's no column
        // title competing for it; the reader's actions claim the far right via the
        // spacer in `ArticleToolbar`.
        if !appState.isFocusMode {
            ToolbarItem(placement: .primaryAction) {
                ListSearchField(text: $appState.searchQuery, prompt: "Search")
                    .frame(width: searchFieldWidth)
            }
        }
        if !appState.isFocusMode, showsSortControl {
            let searching = !appState.searchQuery.isEmpty
            let effectiveSort = searching ? appState.searchSort : appState.sortField
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // While searching, bind to `searchSort` (which offers
                    // Relevance) so the search order stays independent of the
                    // list's persisted sort field.
                    Picker("Sort By", selection: searching ? $appState.searchSort : $appState.sortField) {
                        ForEach(ReadingSort.options(searching: searching)) { field in
                            Text(field.label).tag(field)
                        }
                    }
                    // Relevance has no ascending/descending — hide the order picker.
                    if effectiveSort != .relevance {
                        Divider()
                        Picker("Order", selection: $appState.sortAscending) {
                            Text(effectiveSort.directionLabel(ascending: false)).tag(false)
                            Text(effectiveSort.directionLabel(ascending: true)).tag(true)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort readings")
                .accessibilityIdentifier(A11y.List.sortMenu)
            }
        }
    }

    // ── Context menu ──────────────────────────────────────────────────────

    @ViewBuilder
    private func contextMenu(for row: ReadingRow) -> some View {
        Button(row.read ? "Mark as Unread" : "Mark as Read") {
            Task { await appState.toggleRead(row) }
        }
        .keyboardShortcut(ShortcutCatalog.toggleRead)

        Button(row.favorite ? "Remove from Favorites" : "Add to Favorites") {
            Task { await appState.toggleFavorite(row) }
        }
        .keyboardShortcut(ShortcutCatalog.toggleFavorite)

        Divider()

        if row.archived {
            Button("Move to Library") {
                Task { await appState.unarchive(row) }
            }
        } else {
            Button("Archive") {
                Task { await appState.archive(row) }
            }
            .keyboardShortcut(ShortcutCatalog.archive)
            // ⌘⌫ is "delete to start of line" in a text field; yield to it while
            // editing so typing isn't hijacked into archiving.
            .disabled(appState.isEditingText)
        }

        Divider()

        Button("Delete", role: .destructive) {
            appState.pendingDelete = row
        }
        .keyboardShortcut(ShortcutCatalog.delete)
        .disabled(appState.isEditingText)
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /// Whether the sort control belongs in the toolbar. Hidden only for a
    /// genuinely empty library — it stays put on a no-results search (empty list,
    /// active query).
    ///
    /// `isSearchPending` covers the gap the debounce opens: clearing a no-results
    /// query empties `searchQuery` at once while `readings` stays empty until the
    /// reload lands ~150ms later, and without it both clauses read false for those
    /// frames and the control blinks out.
    private var showsSortControl: Bool {
        !appState.readings.isEmpty || !appState.searchQuery.isEmpty || appState.isSearchPending
    }

    /// Fills the column's toolbar section, less a reserve for the sort menu — sized
    /// so the sort's trailing margin matches the search field's leading one, and the
    /// pair never folds into the toolbar's overflow chevron.
    private var searchFieldWidth: CGFloat {
        max(150, CGFloat(columnWidth) - 76)
    }
}

// ── Row ───────────────────────────────────────────────────────────────────────

struct ReadingRowView: View {
    let row: ReadingRow

    var body: some View {
        // The indicator lives in its own fixed-width leading column so the
        // title, author and excerpt all share the same text column, aligned
        // whether or not the indicator is present (see `ReadingIndicator`).
        HStack(alignment: .top, spacing: 8) {
            ReadingIndicatorView(indicator: .forRow(row))

            VStack(alignment: .leading, spacing: 4) {
                // Title + indicators
                HStack(alignment: .top, spacing: 6) {
                    Text(row.title.isEmpty ? row.url : row.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if row.favorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Favorite")
                    }
                }

                // Site + reading time
                HStack(spacing: 10) {
                    if let site = row.site, !site.isEmpty {
                        Text(site)
                            .lineLimit(1)
                    }
                    if let readingTime = row.readingTimeLabel {
                        Text(readingTime)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Excerpt
                if let excerpt = row.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
