// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Markdown

/// The parsed block structure of an article, computed once from its Markdown.
/// Parsing (`Document(parsing:)` + grouping) is the expensive step of rendering,
/// so callers build this **off the per-render path** — when the article loads —
/// and hand it to `MarkdownDocumentView`. The view then only applies the theme
/// and highlight tinting on each render, never re-parsing. (Previously the parse
/// lived in the view's initializer, so every unrelated re-render of the reader —
/// a highlight toggle, a font change, a selection advance — re-parsed the whole
/// article on the main thread.)
///
/// The document also carries the reading-position anchors (`ArticleAnchors`) and
/// the place of each top-level block among the rendered groups, so the reader can
/// name the block at the top of the window and scroll back to it later.
struct ArticleDocument {
    /// A render unit: either a run of contiguous text blocks — headings,
    /// paragraphs, and image-free lists and quotes — rendered as one selectable
    /// `NSTextView`, or a single non-foldable block (a figure, a table, a code
    /// block, or an image-bearing list/quote) rendered by the SwiftUI block
    /// renderer. Selection is continuous *within* a text run; the non-foldable
    /// blocks form a seam.
    enum RenderGroup: Identifiable {
        case textRun(id: String, blocks: [Markup], firstBlock: Int)
        case other(IdentifiedMarkup, block: Int)

        var id: String {
            switch self {
            case let .textRun(id, _, _): id
            case let .other(item, _): item.id
            }
        }

        /// The position, among all top-level blocks, of the first block the
        /// group shows. The reader adds the position inside the group to it.
        var firstBlock: Int {
            switch self {
            case let .textRun(_, _, firstBlock): firstBlock
            case let .other(_, block): block
            }
        }
    }

    /// Where one top-level block sits among the rendered groups.
    struct BlockLocation: Equatable {
        let groupID: String
        /// The position of the block inside its group. Always 0 for a group
        /// that shows a single block.
        let indexInGroup: Int
    }

    let groups: [RenderGroup]

    /// The reading-position anchors, one for each top-level block.
    let anchors: ArticleAnchors

    /// Where each top-level block sits, indexed by its position in the article.
    let blockLocations: [BlockLocation]

    init(markdown: String) {
        let source = Self.unwrapLinkedImages(markdown)
        let document = Document(parsing: source.text)
        let blocks = Array(document.children)
        groups = Self.makeGroups(blocks)
        anchors = ArticleAnchors(blocks: blocks, body: source.text, extraBlocks: source.extraBlocks)
        blockLocations = Self.makeLocations(groups)
    }

    // ── Reading position ──────────────────────────────────────────────────────

    /// The number of top-level blocks the reader shows.
    var blockCount: Int {
        blockLocations.count
    }

    /// Where the reader must scroll to show the block at `index`.
    func location(ofBlock index: Int) -> BlockLocation? {
        blockLocations.indices.contains(index) ? blockLocations[index] : nil
    }

    /// Resolve a stored position to a block of this document, in the order the
    /// library format gives: the recorded index when its quote still agrees,
    /// then the quote found elsewhere, then the progress. Returns nil when the
    /// article has no blocks, which opens it at the start.
    func blockToRestore(block: Int, quote: String, percent: Float) -> Int? {
        let stored = ArticleAnchors.normalize(quote)
        if let index = anchors.index(ofBlock: block),
           let anchor = anchors.anchor(at: index),
           ArticleAnchors.quotesAgree(stored, anchor.quote)
        {
            return index
        }
        if let index = anchors.index(matchingQuote: stored) {
            return index
        }
        return anchors.index(nearestPercent: percent)
    }

    // ── Grouping ──────────────────────────────────────────────────────────────

    /// Group the document's top-level blocks, merging maximal runs of foldable
    /// blocks (see `isFoldable`). A run takes the source-derived id of its first block,
    /// and each standalone block its own — both distinct source positions, so
    /// ids stay unique across the group list. Each group also records the
    /// position of its first block, so the reader can map a block to a group.
    private static func makeGroups(_ blocks: [Markup]) -> [RenderGroup] {
        var groups: [RenderGroup] = []
        var run: [Markup] = []
        var runStart = 0

        func flush() {
            guard let first = run.first else { return }
            groups.append(.textRun(id: IdentifiedMarkup.stableID(for: first, fallbackIndex: runStart),
                                   blocks: run, firstBlock: runStart))
            run = []
        }

        for (offset, block) in blocks.enumerated() {
            if isFoldable(block) {
                if run.isEmpty {
                    runStart = offset
                }
                run.append(block)
            } else {
                flush()
                groups.append(.other(IdentifiedMarkup(
                    id: IdentifiedMarkup.stableID(for: block, fallbackIndex: offset), markup: block
                ), block: offset))
            }
        }
        flush()
        return groups
    }

    /// The place of every top-level block, in article order. The groups are in
    /// that order too, and a text run holds its blocks in order, so walking the
    /// groups gives one entry per block.
    private static func makeLocations(_ groups: [RenderGroup]) -> [BlockLocation] {
        var locations: [BlockLocation] = []
        for group in groups {
            switch group {
            case let .textRun(id, blocks, _):
                for index in blocks.indices {
                    locations.append(BlockLocation(groupID: id, indexInGroup: index))
                }
            case let .other(item, _):
                locations.append(BlockLocation(groupID: item.id, indexInGroup: 0))
            }
        }
        return locations
    }

    /// Which blocks fold into a shared selectable text run, so a drag-selection
    /// flows continuously across them. `MarkdownTextRun` emits headings,
    /// paragraphs, lists, and quotes into one `NSAttributedString`, so all four
    /// can share a run.
    ///
    /// A block is *not* foldable — and so becomes a standalone group and a
    /// selection seam — when it carries an image: a standalone-image paragraph
    /// (a figure), or a list/quote whose subtree contains any image. The text-run
    /// emitter would flatten an embedded image to its alt text, so those render
    /// via the SwiftUI block views instead, which lay the image out as a figure.
    /// Code blocks, tables, and thematic breaks are likewise never foldable.
    private static func isFoldable(_ block: Markup) -> Bool {
        if block is Heading {
            return true
        }
        if let paragraph = block as? Paragraph {
            return !paragraph.children.contains { standaloneImage($0) != nil }
        }
        if block is UnorderedList || block is OrderedList || block is BlockQuote {
            return !containsImage(block)
        }
        return false
    }

    /// True if the block's subtree contains any image. Lists and quotes fold into
    /// a text run only when image-free, since `MarkdownTextRun` would otherwise
    /// flatten the image to alt text.
    private static func containsImage(_ markup: Markup) -> Bool {
        if markup is Markdown.Image {
            return true
        }
        return markup.children.contains { containsImage($0) }
    }

    /// Mirrors `ParagraphView.standaloneImage`: a bare image, or a link wrapping
    /// a single image. Such paragraphs render as figures, not text.
    private static func standaloneImage(_ markup: Markup) -> Markdown.Image? {
        if let image = markup as? Markdown.Image {
            return image
        }
        if let link = markup as? Markdown.Link {
            let children = Array(link.children)
            let images = children.compactMap { $0 as? Markdown.Image }
            let meaningful = children.filter { child in
                if let text = child as? Markdown.Text {
                    return !text.string.trimmingCharacters(in: .whitespaces).isEmpty
                }
                return true
            }
            if images.count == 1, meaningful.count == 1 {
                return images.first
            }
        }
        return nil
    }

    // ── Source transform ──────────────────────────────────────────────────────

    /// Collapse a link wrapping a single image — `[![alt](img)](url)`, often
    /// split across blank lines by the extension's HTML→Markdown step as
    /// `[\n\n![alt](img)\n\n](url)` — down to the bare image. When the wrapper
    /// spans blank lines CommonMark can't parse it as one link, so it would
    /// otherwise leak a literal `[` and `](url)` around the picture. The image
    /// itself is already stored locally; the outer link target is dropped.
    ///
    /// Such a match joins blocks that blank lines separate in the raw body, so
    /// the result also reports how many blocks the raw body holds in addition,
    /// and where. The library format counts blocks in the raw body.
    private static func unwrapLinkedImages(
        _ markdown: String
    ) -> (text: String, extraBlocks: [ArticleAnchors.ExtraBlocks]) {
        let pattern = #"\[\s*(!\[[^\]]*\]\([^)]*\))\s*\]\([^)]*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (markdown, [])
        }
        let source = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (markdown, []) }

        var out = ""
        var extras: [ArticleAnchors.ExtraBlocks] = []
        var cursor = 0
        for match in matches where match.numberOfRanges > 1 {
            let imageRange = match.range(at: 1)
            guard imageRange.location != NSNotFound else { continue }
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let joined = blankLineCount(in: source.substring(with: match.range))
            if joined > 0 {
                extras.append(ArticleAnchors.ExtraBlocks(offset: out.count, count: joined))
            }
            out += source.substring(with: imageRange)
            cursor = match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return (out, extras)
    }

    /// How many blank lines break `text` into separate blocks. Each one is a
    /// block the raw body holds and the parsed copy does not.
    private static func blankLineCount(in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"\n[ \t]*\n"#) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}

extension ArticleDocument {
    /// Parse `markdown` off the calling actor. swift-markdown builds the whole
    /// tree in one synchronous pass — long enough on a large article to stall
    /// the main thread — so callers await this rather than calling
    /// `init(markdown:)` on the main actor.
    static func parse(markdown: String) async -> ArticleDocument {
        let parsed = await Task.detached(priority: .userInitiated) {
            Parsed(document: ArticleDocument(markdown: markdown))
        }.value
        return parsed.document
    }

    /// Lets a document parsed in a detached task cross back to the caller's
    /// actor. Safe because the tree is fully built inside the task and never
    /// mutated afterward — ownership transfers with the box. (swift-markdown's
    /// `Markup` nodes don't declare `Sendable`.)
    private struct Parsed: @unchecked Sendable {
        let document: ArticleDocument
    }
}
