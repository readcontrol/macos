// SPDX-License-Identifier: GPL-3.0-or-later

// Thin wrapper around the UniFFI-generated `Database` object.
// All calls are dispatched to a background actor so the UI stays responsive.

import Foundation

actor CoreBridge {
    private let database: Database
    private let libraryPath: String

    init(libraryPath: String, dbPath: String) throws {
        self.libraryPath = libraryPath
        database = try Database.open(dbPath: dbPath)
    }

    // ── Indexing ──────────────────────────────────────────────────────────

    func rebuild() throws {
        try database.rebuild(libraryPath: libraryPath)
    }

    @discardableResult
    func sync() throws -> UInt32 {
        try database.sync(libraryPath: libraryPath)
    }

    // ── Query ─────────────────────────────────────────────────────────────

    /// One page of readings for the composed view/tag/rating filter, the chosen
    /// sort, and an optional full-text query. Takes app-language values and builds
    /// the core's `FfiListOptions` here so the `Ffi*` query DTO stays in the bridge.
    func listReadings(_ query: ReadingQuery) throws -> [FfiReadingRow] {
        let opts = FfiListOptions(
            view: query.view.ffiView,
            sort: query.sort.ffiSort,
            ascending: query.ascending,
            tag: query.tag,
            rating: query.rating,
            since: nil, until: nil,
            query: query.search,
            limit: query.limit, offset: query.offset
        )
        return try database.listReadings(opts: opts)
    }

    /// All three sidebar count sections — view badges, tag counts, rating counts
    /// — in one call, scoped by the active search + selected facets. Resolves the
    /// full-text match once and returns them together. Builds the core's
    /// `FfiCountScope` here so the query DTO stays in the bridge.
    func sidebarCounts(
        view: SidebarItem, tag: String?, rating: UInt8?, query: String?
    ) throws -> FfiSidebarCounts {
        let scope = FfiCountScope(view: view.ffiView, tag: tag, rating: rating, query: query)
        return try database.sidebarCounts(scope: scope)
    }

    func getReadingRow(id: String) throws -> FfiReadingRow? {
        try database.getReadingRow(id: id)
    }

    func getBody(id: String) throws -> String? {
        try database.getBody(id: id)
    }

    // ── Tags ──────────────────────────────────────────────────────────────

    func addTag(id: String, tag: String) throws {
        try database.addTag(libraryPath: libraryPath, id: id, tag: tag)
    }

    func removeTag(id: String, tag: String) throws {
        try database.removeTag(libraryPath: libraryPath, id: id, tag: tag)
    }

    // ── Status flags ──────────────────────────────────────────────────────

    func setRead(id: String, read: Bool) throws {
        try database.setRead(libraryPath: libraryPath, id: id, read: read)
    }

    func setArchived(id: String, archived: Bool) throws {
        try database.setArchived(libraryPath: libraryPath, id: id, archived: archived)
    }

    func setFavorite(id: String, favorite: Bool) throws {
        try database.setFavorite(libraryPath: libraryPath, id: id, favorite: favorite)
    }

    // ── Ratings ───────────────────────────────────────────────────────────

    /// Set a reading's star rating (0–5, where 0 clears it).
    func setRating(id: String, rating: UInt8) throws {
        try database.setRating(libraryPath: libraryPath, id: id, rating: rating)
    }

    // ── Deletion ──────────────────────────────────────────────────────────

    /// Permanently delete a reading (file, assets, and index row).
    func deleteReading(id: String) throws {
        try database.deleteReading(libraryPath: libraryPath, id: id)
    }

    // ── Highlights ────────────────────────────────────────────────────────

    func listHighlights(readingId: String) throws -> [FfiHighlight] {
        try database.listHighlights(libraryPath: libraryPath, readingId: readingId)
    }

    @discardableResult
    func addHighlight(readingId: String, text: String) throws -> FfiHighlight {
        try database.addHighlight(libraryPath: libraryPath, readingId: readingId, text: text)
    }

    /// Toggle a highlight by its text. Returns `true` if highlighted after the
    /// call, `false` if it was cleared.
    @discardableResult
    func toggleHighlight(readingId: String, text: String) throws -> Bool {
        try database.toggleHighlight(libraryPath: libraryPath, readingId: readingId, text: text)
    }

    func deleteHighlight(readingId: String, highlightId: String) throws {
        try database.deleteHighlight(libraryPath: libraryPath, readingId: readingId, highlightId: highlightId)
    }

    // ── Reading position ──────────────────────────────────────────────────

    /// Where the user stopped in a reading. Nil when the reading has no
    /// position, or when its position file is damaged.
    func getPosition(readingId: String) throws -> FfiPosition? {
        try database.getPosition(libraryPath: libraryPath, readingId: readingId)
    }

    /// Record where the user stopped: the index of the anchor block, the start
    /// of that block, the progress before it, and how far into the block the
    /// stop is. Returns the stored position. The core returns nil when it clears
    /// the position, because block 0 is the start of the article.
    @discardableResult
    func setPosition(readingId: String, block: UInt32, quote: String,
                     percent: Float, offset: Float) throws -> FfiPosition?
    {
        try database.setPosition(libraryPath: libraryPath, readingId: readingId,
                                 block: block, quote: quote, percent: percent, offset: offset)
    }

    /// Remove the reading position. The next open starts at the top.
    func clearPosition(readingId: String) throws {
        try database.clearPosition(libraryPath: libraryPath, readingId: readingId)
    }
}
