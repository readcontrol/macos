// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Builds a `ReadingRow` for logic tests, defaulting every field so a test sets
/// only the flags it exercises. The non-flag fields are fixed placeholders; the
/// smart-view and reading-time logic never reads them.
func makeReadingRow(
    read: Bool = false,
    archived: Bool = false,
    favorite: Bool = false,
    wordCount: UInt32? = nil,
    progress: Float? = nil
) -> ReadingRow {
    ReadingRow(
        id: "01JQ0000000000000000000000",
        title: "Placeholder",
        url: "https://example.com/a",
        canonicalUrl: "https://example.com/a",
        author: nil,
        site: nil,
        savedAt: "2026-01-01T00:00:00Z",
        read: read,
        archived: archived,
        favorite: favorite,
        rating: 0,
        excerpt: nil,
        wordCount: wordCount,
        lang: nil,
        tags: [],
        progress: progress
    )
}
