// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// ── Mutations ────────────────────────────────────────────────────────────────
// Row edits (read/favorite/rating/archive/tags/delete) with optimistic UI:
// each edit lands on screen within a frame, then the core write + `refresh()`
// reconcile.

extension AppState {
    /// Optimistically apply an edit so it shows on the next frame, before the
    /// core write + `refresh()` land: swap the row in the visible list (if
    /// present) and fold the before/after into the sidebar aggregates. Removing a
    /// row that no longer matches the filter is the separate, explicit job of
    /// `advancePastFilteredRow`; re-ordering is left to the follow-up `refresh()`.
    /// A failed write self-heals: the refresh re-reads the index and overwrites
    /// both the row and the counts.
    private func applyOptimistic(_ old: ReadingRow, _ new: ReadingRow) {
        if let index = readings.firstIndex(where: { $0.id == old.id }) {
            readings[index] = new
        }
        // The optimistic view-badge delta is faceted by the active tag/rating
        // selection, mirroring the core's count queries. It can't evaluate the FTS
        // query in Swift, so while searching we skip it and let the authoritative
        // recount in `refresh()` → `loadSidebar()` update the badges instead. (The
        // Tags/Ratings badges always come from that recount — see `applyDelta`.)
        if searchQuery.isEmpty {
            sidebar.applyDelta(from: old, to: new, tag: selectedTag, rating: selectedRating)
        }
    }

    /// Mirror of the core's view/tag/rating filter (see `list.rs`): does `row`
    /// still belong in the list the user is currently looking at?
    private func rowMatchesCurrentFilter(_ row: ReadingRow) -> Bool {
        ComposedFilter.matches(row, view: activeView, tag: selectedTag, rating: selectedRating)
    }

    /// Pair with `applyOptimistic` for status changes: if the optimistic edit
    /// pushed the row out of the current filter, slide it out and advance the
    /// selection to an adjacent row in the *same* render tick — one motion, not
    /// an in-place icon flip followed a beat later by the row jumping away. A
    /// no-op when the row still matches (e.g. marking read in the All view).
    /// Skipped during search, whose results span every view.
    private func advancePastFilteredRow(id: String) {
        guard searchQuery.isEmpty,
              let index = readings.firstIndex(where: { $0.id == id }),
              !rowMatchesCurrentFilter(readings[index]) else { return }
        withAnimation {
            if selectedId == id {
                selectedId = ComposedFilter.selectionAfterRemoving(at: index, from: readings)
            }
            readings.remove(at: index)
        }
    }

    func toggleRead(_ row: ReadingRow) async {
        guard let core else { return }
        var updated = row
        updated.read = !row.read
        applyOptimistic(row, updated)
        advancePastFilteredRow(id: row.id)
        try? await core.setRead(id: row.id, read: updated.read)
        await refresh()
    }

    /// Mark a reading read because the user reached its end. A reading that is
    /// already read stays as it is, so its read date keeps the time the user
    /// first finished it. The core clears the reading position.
    ///
    /// The user is still in the article, thus the selection stays on it and the
    /// reader keeps it open. When the reading no longer matches the current
    /// filter (e.g. the Unread view), its row leaves the list, but the selection
    /// does not move to another row. Returns the refreshed row, so the reader
    /// can update its own copy.
    @discardableResult
    func markRead(id: String) async -> ReadingRow? {
        guard let core else { return nil }
        if let row = readings.first(where: { $0.id == id }) {
            guard !row.read else { return row }
            var updated = row
            updated.read = true
            updated.progress = nil
            applyOptimistic(row, updated)
            dropFilteredRowKeepingSelection(id: id)
        }
        try? await core.setRead(id: id, read: true)
        // Marking read keeps the reading position in the core, so clear it here:
        // the article is finished, thus the next open starts at the top.
        try? await core.clearPosition(readingId: id)
        await refresh()
        if let row = readings.first(where: { $0.id == id }) {
            return row
        }
        guard let fetched = try? await core.getReadingRow(id: id) else { return nil }
        return ReadingRow(fetched)
    }

    /// Remove the row from the list when it no longer matches the current
    /// filter, and keep the selection on it. The reader still shows the reading.
    /// Skipped during search, whose results span every view.
    private func dropFilteredRowKeepingSelection(id: String) {
        guard searchQuery.isEmpty,
              let index = readings.firstIndex(where: { $0.id == id }),
              !rowMatchesCurrentFilter(readings[index]) else { return }
        withAnimation {
            _ = readings.remove(at: index)
        }
    }

    func toggleFavorite(_ row: ReadingRow) async {
        guard let core else { return }
        var updated = row
        updated.favorite = !row.favorite
        applyOptimistic(row, updated)
        advancePastFilteredRow(id: row.id)
        try? await core.setFavorite(id: row.id, favorite: updated.favorite)
        await refresh()
    }

    /// Set a reading's star rating (0–5, 0 clears it). Returns the refreshed
    /// row so detail views can update their local copy.
    @discardableResult
    func setRating(id: String, rating: UInt8) async -> ReadingRow? {
        guard let core else { return nil }
        if let old = readings.first(where: { $0.id == id }) {
            var updated = old
            updated.rating = rating
            applyOptimistic(old, updated)
        }
        try? await core.setRating(id: id, rating: rating)
        await refresh()
        // The row may have left the current filtered list (e.g. its rating no
        // longer matches), so fall back to fetching it straight from the index.
        if let row = readings.first(where: { $0.id == id }) {
            return row
        }
        guard let fetched = try? await core.getReadingRow(id: id) else { return nil }
        return ReadingRow(fetched)
    }

    func archive(_ row: ReadingRow) async {
        guard let core else { return }
        var updated = row
        updated.archived = true
        applyOptimistic(row, updated)
        advancePastFilteredRow(id: row.id)
        try? await core.setArchived(id: row.id, archived: true)
        await refresh()
    }

    func unarchive(_ row: ReadingRow) async {
        guard let core else { return }
        var updated = row
        updated.archived = false
        applyOptimistic(row, updated)
        advancePastFilteredRow(id: row.id)
        try? await core.setArchived(id: row.id, archived: false)
        await refresh()
    }

    /// Permanently delete a reading: removes its file and assets from disk and
    /// its row from the index. Irreversible — callers should confirm first.
    func delete(_ row: ReadingRow) async {
        guard let core else { return }
        do {
            try await core.deleteReading(id: row.id)
            if selectedId == row.id {
                selectedId = nil
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addTag(id: String, tag: String) async {
        guard let core else { return }
        // Mirror the core: trim, dedup on exact match, append (no sort/lowercase),
        // so the optimistic chip lands in the same place the reload confirms.
        let tag = tag.trimmingCharacters(in: .whitespaces)
        if let old = readings.first(where: { $0.id == id }), !old.tags.contains(tag) {
            var updated = old
            updated.tags.append(tag)
            applyOptimistic(old, updated)
        }
        try? await core.addTag(id: id, tag: tag)
        await refresh()
    }

    func removeTag(id: String, tag: String) async {
        guard let core else { return }
        if let old = readings.first(where: { $0.id == id }), old.tags.contains(tag) {
            var updated = old
            updated.tags.removeAll { $0 == tag }
            applyOptimistic(old, updated)
        }
        try? await core.removeTag(id: id, tag: tag)
        await refresh()
    }

    func getBody(id: String) async -> String? {
        guard let core else { return nil }
        return try? await core.getBody(id: id)
    }

    /// Re-fetch a single reading row from the index (e.g. after a tag edit) so
    /// detail views can refresh their local copy without a full list reload.
    func reloadRow(id: String) async -> ReadingRow? {
        guard let core else { return nil }
        guard let fetched = try? await core.getReadingRow(id: id) else { return nil }
        return ReadingRow(fetched)
    }
}
