// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Markdown

/// The reading-position anchors of one article: for each top-level block the
/// reader shows, the three values the library format keeps — the index of the
/// block, a short quote of its start, and the progress before it. See the
/// "Reading position" section of `docs/library-format.md`.
///
/// The format counts blocks in the body as it is on disk. The reader parses a
/// transformed copy, because `unwrapLinkedImages` joins a link that wraps an
/// image. When such a link spans blank lines, the raw body holds more blocks
/// than the parsed copy holds. `extraBlocks` carries that difference, so a
/// recorded index stays an index into the raw body.
///
/// The quote is the text of the block, not its Markdown source: a heading gives
/// `Intro`, not `## Intro`. A search for that text still finds the block in the
/// source. A block without text, such as a code block or a table, gives an empty
/// quote; its index still names it.
struct ArticleAnchors: Equatable {
    /// What the reader records for one block.
    struct Anchor: Equatable {
        /// 0-based index of the block in the raw body.
        let block: Int
        /// The start of the block, on one line, at most `quoteLength` characters.
        let quote: String
        /// The body characters before the block, divided by all body characters.
        let percent: Float
    }

    /// How many blocks the raw body holds in addition to the parsed copy, and
    /// where. `offset` is a character offset into the parsed body.
    struct ExtraBlocks: Equatable {
        let offset: Int
        let count: Int
    }

    /// The longest quote the format keeps. The core cuts to the same length.
    static let quoteLength = 120

    /// One anchor for each top-level block, in the order the reader shows them.
    let anchors: [Anchor]

    /// Build the anchors of a parsed body.
    ///
    /// - Parameters:
    ///   - blocks: the top-level blocks, in the order the reader shows them.
    ///   - body: the parsed body the blocks come from.
    ///   - extraBlocks: the blocks the parse merged, in offset order.
    init(blocks: [Markup], body: String, extraBlocks: [ExtraBlocks] = []) {
        let lineStarts = Self.lineStartCounts(body)
        let total = max(body.count, 1)
        var pending = extraBlocks
        var extraSoFar = 0
        var previousStart = 0
        var result: [Anchor] = []

        for (index, block) in blocks.enumerated() {
            let start = Self.startCount(of: block, lineStarts: lineStarts, default: previousStart)
            previousStart = start
            // A merge before this block moves it down the raw body. A merge
            // inside it does not move the block itself, thus it waits for the
            // block that follows.
            while let first = pending.first, first.offset < start {
                extraSoFar += first.count
                pending.removeFirst()
            }
            result.append(Anchor(
                block: index + extraSoFar,
                quote: Self.quote(of: block),
                percent: min(Float(start) / Float(total), 1)
            ))
        }
        anchors = result
    }

    // ── Lookup ────────────────────────────────────────────────────────────────

    /// The anchor of the block the reader shows at `index`.
    func anchor(at index: Int) -> Anchor? {
        anchors.indices.contains(index) ? anchors[index] : nil
    }

    /// The block that carries the raw-body index `block`.
    func index(ofBlock block: Int) -> Int? {
        anchors.firstIndex { $0.block == block }
    }

    /// The first block whose text agrees with `quote`. The reader uses it when
    /// the body changed and the index no longer names the same text.
    func index(matchingQuote quote: String) -> Int? {
        let needle = Self.normalize(quote)
        guard !needle.isEmpty else { return nil }
        return anchors.firstIndex { Self.quotesAgree(needle, $0.quote) }
    }

    /// Whether a stored quote and the quote of a block name the same text. Each
    /// client cuts a quote to its own length, thus one is accepted as the start
    /// of the other. Two empty quotes agree, because a block without text always
    /// gives an empty quote.
    static func quotesAgree(_ stored: String, _ found: String) -> Bool {
        if stored.isEmpty || found.isEmpty {
            return stored.isEmpty && found.isEmpty
        }
        return found.hasPrefix(stored) || stored.hasPrefix(found)
    }

    /// The last block that starts at or before `percent`. The reader uses it
    /// when neither the index nor the quote finds the block.
    func index(nearestPercent percent: Float) -> Int? {
        guard !anchors.isEmpty else { return nil }
        let last = anchors.lastIndex { $0.percent <= percent }
        return last ?? 0
    }

    // ── Building blocks ───────────────────────────────────────────────────────

    /// The text of a block, on one line and cut to `quoteLength` characters.
    /// The core applies the same rules, thus a value it reads back is equal.
    static func quote(of block: Markup) -> String {
        String(normalize(InlineRenderer.plainText(block)).prefix(quoteLength))
    }

    /// Put text on one line: each run of white space becomes one space.
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The character offset of each line of `body`, indexed by 0-based line.
    private static func lineStartCounts(_ body: String) -> [Int] {
        var starts = [0]
        var count = 0
        for character in body {
            count += 1
            if character == "\n" {
                starts.append(count)
            }
        }
        return starts
    }

    /// Where a block starts, counted in characters from the start of the body.
    /// A block without source information keeps the start of the block before
    /// it, which keeps the progress in order.
    private static func startCount(of block: Markup, lineStarts: [Int], default fallback: Int) -> Int {
        guard let line = block.range?.lowerBound.line, line >= 1, line - 1 < lineStarts.count else {
            return fallback
        }
        return lineStarts[line - 1]
    }
}
