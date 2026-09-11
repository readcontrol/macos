// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// ── Reading position ─────────────────────────────────────────────────────────
// Where the user stopped in a reading. The core owns the position file and the
// index column; the reader only asks for a position and reports a new one. Each
// call goes to the core off the main thread, and none of them touches the
// reading list, so a scroll never redraws the list.

extension AppState {
    /// The stored position of a reading. Nil when the reading has none, or when
    /// its position file is damaged.
    func position(id: String) async -> ReadingPosition? {
        guard let core else { return nil }
        // `try?` folds the error and the absent position into one nil, which is
        // what the reader wants: both mean "start at the top".
        guard let stored = try? await core.getPosition(readingId: id) else { return nil }
        return ReadingPosition(stored)
    }

    /// Record where the user stopped. The core cleans the values, writes the
    /// position file, and updates the index row. A block of 0 is the start of
    /// the article, which the core stores as "no position".
    func recordPosition(id: String, block: Int, quote: String, percent: Float) async {
        guard let core, block >= 0 else { return }
        try? await core.setPosition(readingId: id, block: UInt32(block),
                                    quote: quote, percent: percent)
    }

    /// Remove the position of a reading, so the next open starts at the top.
    func clearPosition(id: String) async {
        guard let core else { return }
        try? await core.clearPosition(readingId: id)
    }
}
