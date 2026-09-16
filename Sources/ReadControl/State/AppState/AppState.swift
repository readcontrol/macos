// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SwiftUI

// The behavior lives in sibling extension files in this folder, one per
// concern: Library.swift (onboarding, boot, sync), Readings.swift (list
// loading, search, sidebar reloads), Mutations.swift (row edits with
// optimistic UI), and Highlights.swift. This file holds the stored state,
// `init`, and the AppKit focus helpers.
@MainActor
@Observable
final class AppState {
    private enum SortDefaultsKey {
        static let field = "sortField"
        static let ascending = "sortAscending"
    }

    /// Keys the composed filter (smart view, tag, rating) and the search box
    /// persist under, so closing the app and reopening it lands on the same view.
    private enum FilterDefaultsKey {
        static let view = "activeView"
        static let tag = "selectedTag"
        static let rating = "selectedRating"
        static let search = "searchQuery"
        /// The reading open when the app quit, so reopening the app opens it again.
        static let reading = "selectedReadingId"
    }

    private enum ExtensionSetupKey {
        /// The step is owed but not yet dismissed — persisted so quitting mid-step
        /// resumes on it.
        static let pending = "extensionSetupPending"
        /// The user has dismissed the step for good — persisted so it never shows
        /// again, including when they later re-pick a library from Settings.
        static let completed = "extensionSetupCompleted"
    }

    /// ── Navigation state ──────────────────────────────────────────────────
    var libraryURL: URL?

    /// True from launch until the first boot from a persisted bookmark settles.
    /// `libraryURL` is only set at the end of the async `boot`, so without this
    /// flag the brief gap between launch and boot would flash the onboarding
    /// screen even when a saved library exists. Onboarding keys off both:
    /// show it only when there's no library *and* we aren't restoring one.
    var isRestoringLibrary: Bool = false

    /// Whether the extension-install step should show ahead of the main view (see
    /// `ContentView`). Raised on a fresh library pick (`pickLibrary`) and cleared
    /// only when the user taps "Continue" — never by boot — so quitting mid-step
    /// and relaunching resumes on the step instead of dropping into the library.
    ///
    /// Persisted so the step survives a relaunch; `init` restores it. Only the
    /// fresh-pick path raises it, so a library set up before this step existed (or
    /// one already dismissed) never shows it. Assigning in `init` doesn't fire the
    /// `didSet`, so restoring the flag doesn't re-write the same value.
    var showExtensionSetup: Bool = false {
        didSet {
            AppDefaults.store.set(showExtensionSetup, forKey: ExtensionSetupKey.pending)
        }
    }

    var readings: [ReadingRow] = []

    /// The open reading. Persisted across launches, so the app opens the last
    /// reading again (see `resumeLastReading`). The reading can be outside the
    /// list: on a page not loaded yet, or not in the current filter.
    var selectedId: String? {
        didSet {
            guard selectedId != oldValue else { return }
            AppDefaults.store.set(selectedId, forKey: FilterDefaultsKey.reading)
        }
    }

    /// The reading that was open when the app quit, if any.
    var lastReadingId: String? {
        AppDefaults.store.string(forKey: FilterDefaultsKey.reading)
    }

    /// The reading-list search text, persisted across launches so a search the
    /// user left active is restored on reopen. `init` seeds it from the store.
    var searchQuery: String = "" {
        didSet {
            AppDefaults.store.set(searchQuery, forKey: FilterDefaultsKey.search)
        }
    }

    /// Sort applied while a search is active. Kept separate from `sortField` so
    /// searching (which defaults to relevance) never clobbers the list's own
    /// persisted sort. Not persisted — a fresh search starts on relevance.
    var searchSort: ReadingSort = .relevance

    /// True between a search-field edit and its debounced reload landing. During
    /// that window `readings` still describes the *previous* query, so UI keyed off
    /// "does the list have rows" holds its shape rather than flickering on the
    /// stale answer (see `ReadingListView.showsSortControl`).
    var isSearchPending: Bool = false

    /// Pending debounced search reload. Each keystroke cancels the previous one
    /// so the core is queried once typing settles, not per character. Plumbing
    /// only — not part of the observable UI state.
    @ObservationIgnored var searchTask: Task<Void, Never>?

    /// The active smart view. Always exactly one — `.all` is the unfiltered base.
    /// Independent from the tag and rating filters so all three compose (together
    /// with the search box): the reading list and the faceted counts are scoped by
    /// `activeView` ∩ `selectedTag` ∩ `selectedRating` ∩ `searchQuery`.
    ///
    /// Persisted across launches; `init` restores it, defaulting to `.unread` on a
    /// first run so the app opens on the pile to work through, not everything.
    var activeView: SidebarItem = .unread {
        didSet {
            AppDefaults.store.set(activeView.rawValue, forKey: FilterDefaultsKey.view)
        }
    }

    /// The active tag filter, if any. Composes with the view, rating, and search;
    /// `nil` means no tag filter. At most one tag at a time. Persisted across launches.
    var selectedTag: String? {
        didSet {
            AppDefaults.store.set(selectedTag, forKey: FilterDefaultsKey.tag)
        }
    }

    /// The active rating filter (1–5), if any. Composes with the view, tag, and
    /// search; `nil` means no rating filter. At most one rating at a time. Persisted
    /// across launches (stored as an `Int`; cleared when `nil`).
    var selectedRating: UInt8? {
        didSet {
            AppDefaults.store.set(selectedRating.map { Int($0) }, forKey: FilterDefaultsKey.rating)
        }
    }

    /// Sort field for the reading list, persisted across launches. The default
    /// here only initializes the backing store; `init` immediately overwrites it
    /// with the persisted preference (re-persisting the same value harmlessly).
    var sortField: ReadingSort = .savedAt {
        didSet {
            AppDefaults.store.set(sortField.rawValue, forKey: SortDefaultsKey.field)
        }
    }

    /// Sort direction (ascending when `true`), persisted across launches.
    /// Descending is the default for every field.
    var sortAscending: Bool = false {
        didSet {
            AppDefaults.store.set(sortAscending, forKey: SortDefaultsKey.ascending)
        }
    }

    /// Reading awaiting delete confirmation, if any. Drives the confirm dialog.
    var pendingDelete: ReadingRow?

    /// Drives the tag-picker sheet for the open reading. Held here (rather than in
    /// the detail view) so both the toolbar button and the ⌘⇧T menu command can
    /// open it.
    var showTagSheet: Bool = false

    /// Drives the highlights inspector for the open reading. Opened from the
    /// Article menu and its ⌘⇧H shortcut.
    var showHighlights: Bool = false

    /// Drives the popover telling the user to select some text first, raised when
    /// the toolbar's Highlight button is pressed with nothing selected.
    var showHighlightHint: Bool = false

    /// Drives the keyboard-shortcuts cheat sheet (the ⌘/ command).
    var showShortcuts: Bool = false

    /// Highlights for the currently open reading. Drives both the reader's
    /// in-text tinting and the highlights inspector.
    var highlights: [HighlightRow] = []

    // ── Sidebar metadata ──────────────────────────────────────────────────

    /// Sidebar badge numbers (view counts, tag counts, rating counts) with
    /// their optimistic delta bookkeeping; reconciled by `loadSidebar()`.
    var sidebar = SidebarCounts()

    // ── Status ────────────────────────────────────────────────────────────
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var hasMoreReadings: Bool = false
    var error: String?

    /// True while the user is editing a text field (the toolbar search field, the
    /// tag picker, …). macOS dispatches menu/context-menu key-equivalents *before*
    /// the focused field editor, so a global ⌘⌫ ("Archive") would fire mid-edit
    /// instead of deleting the line. Commands whose shortcuts collide with the
    /// field editor's own keys disable themselves while this holds, letting the
    /// keystroke fall through to standard text editing. Kept in sync by
    /// `editingMonitor` (see `TextEditingMonitor`).
    var isEditingText: Bool = false
    var isFocusMode: Bool = false

    // Internal rather than private so the sibling extension files in this
    // folder can reach them — Swift's `private` is file-scoped.
    let pageSize: UInt32 = 100
    var core: (any CoreBridging)?
    var accessedURL: URL?
    var watcher: FolderWatcher?

    private var editingMonitor: TextEditingMonitor?

    init() {
        // Restore the persisted sort preference (defaults: saved-at, descending).
        let defaults = AppDefaults.store
        sortField = defaults.string(forKey: SortDefaultsKey.field)
            .flatMap(ReadingSort.init(rawValue:)) ?? .savedAt
        sortAscending = defaults.bool(forKey: SortDefaultsKey.ascending)

        // Restore the view/tag/rating filters and the search box the user left last
        // time. A first run has none of these, so the view falls back to `.unread`
        // and the rest to empty — the app's default landing state. (Assigning in
        // `init` doesn't fire the `didSet`s, so this reads the store without
        // re-writing it.)
        activeView = defaults.string(forKey: FilterDefaultsKey.view)
            .flatMap(SidebarItem.init(rawValue:)) ?? .unread
        selectedTag = defaults.string(forKey: FilterDefaultsKey.tag)
        selectedRating = (defaults.object(forKey: FilterDefaultsKey.rating) as? Int)
            .flatMap { UInt8(exactly: $0) }
        searchQuery = defaults.string(forKey: FilterDefaultsKey.search) ?? ""

        // Resume the extension-install step if the user quit before dismissing it.
        // Set before the restore boot below so, once boot flips `libraryURL`, the
        // step shows immediately with no reading-list flash.
        showExtensionSetup = defaults.bool(forKey: ExtensionSetupKey.pending)

        if TestHooks.isUITesting {
            // UI-testing: never resolve the persisted bookmark (leave the dev's
            // real library untouched). Boot the pinned temp library if one was
            // given; otherwise fall through to the onboarding screen.
            if let path = TestHooks.libraryPath {
                isRestoringLibrary = true
                Task { await boot(url: URL(fileURLWithPath: path)) }
            }
        } else if let url = LibraryBookmark.resolve() {
            accessedURL = url
            isRestoringLibrary = true
            Task { await boot(url: url) }
        }

        editingMonitor = TextEditingMonitor { [weak self] editing in
            self?.isEditingText = editing
        }
    }

    // ── Extension setup ─────────────────────────────────────────────────────────

    /// Whether the user has finished the extension-install step. Once set it stays
    /// set, so a later re-pick of the library (Settings › Change Library…) doesn't
    /// resurface the step — it's a first-run-only prompt.
    var hasCompletedExtensionSetup: Bool {
        AppDefaults.store.bool(forKey: ExtensionSetupKey.completed)
    }

    /// Dismiss the extension-install step and remember it's done for good. Backs
    /// the step's "Continue" button.
    func completeExtensionSetup() {
        AppDefaults.store.set(true, forKey: ExtensionSetupKey.completed)
        showExtensionSetup = false
    }

    // ── Search focus ──────────────────────────────────────────────────────────

    /// Focus the reading-list search field (⌘K). SwiftUI exposes no focus binding
    /// for it, so we reach the `NSSearchField` through AppKit (see `ListSearchField`).
    func focusSearchField() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        // The toolbar is hosted alongside `contentView`, not within it, so search
        // from the frame view (their shared ancestor) to reach the field.
        let root = window.contentView?.superview ?? window.contentView
        guard let root, let field = Self.firstSearchField(in: root) else { return }
        window.makeFirstResponder(field)
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField {
            return field
        }
        for subview in view.subviews {
            if let field = firstSearchField(in: subview) {
                return field
            }
        }
        return nil
    }
}
