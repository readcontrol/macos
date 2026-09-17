// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// ── Reading position ─────────────────────────────────────────────────────────
// The core owns the position file and the index column; the reader only asks
// for a position and reports a new one.

extension AppState {
    /// The stored position of a reading. Nil when it has none, or when its
    /// position file is damaged — both mean "start at the top".
    func position(id: String) async -> ReadingPosition? {
        guard let core, let stored = try? await core.getPosition(readingId: id) else { return nil }
        return ReadingPosition(stored)
    }

    /// Record where the user stopped. The core cleans the values, writes the
    /// file, and updates the index row. Block 0 is the start of the article,
    /// which the core stores as "no position". `offset` is how far into the
    /// anchor block the stop is, from 0.0 to 1.0.
    func recordPosition(id: String, block: Int, quote: String, percent: Float, offset: Float) async {
        guard let core, block >= 0 else { return }
        try? await core.setPosition(readingId: id, block: UInt32(block),
                                    quote: quote, percent: percent, offset: offset)
    }

    /// Remove the position, so the next open starts at the top.
    func clearPosition(id: String) async {
        guard let core else { return }
        try? await core.clearPosition(readingId: id)
    }
}
