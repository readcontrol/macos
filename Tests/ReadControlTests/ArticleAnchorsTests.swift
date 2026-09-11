// SPDX-License-Identifier: GPL-3.0-or-later

import Markdown
import XCTest

/// The reading position is anchored to a top-level block of the body. These
/// tests pin the three values the library format stores — the index, the quote,
/// and the progress — and the order in which the reader resolves them again.
final class ArticleAnchorsTests: XCTestCase {
    private let body = """
    # Title

    First paragraph of the article.

    ## A section

    Second paragraph, further down.
    """

    private func document() -> ArticleDocument {
        ArticleDocument(markdown: body)
    }

    func testAnchorsDescribeEveryBlockInOrder() {
        let anchors = document().anchors.anchors
        XCTAssertEqual(anchors.count, 4)
        XCTAssertEqual(anchors.map(\.block), [0, 1, 2, 3])
        XCTAssertEqual(anchors[0].quote, "Title")
        XCTAssertEqual(anchors[1].quote, "First paragraph of the article.")
        XCTAssertEqual(anchors[2].quote, "A section")
    }

    func testProgressGrowsAndStaysInRange() {
        let anchors = document().anchors.anchors
        XCTAssertEqual(anchors[0].percent, 0)
        for (earlier, later) in zip(anchors, anchors.dropFirst()) {
            XCTAssertLessThan(earlier.percent, later.percent)
        }
        XCTAssertLessThanOrEqual(anchors.last?.percent ?? 1, 1)
    }

    func testQuoteIsOneLineAndCut() {
        let long = String(repeating: "word ", count: 60)
        let anchors = ArticleDocument(markdown: long).anchors.anchors
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors[0].quote.count, ArticleAnchors.quoteLength)
        XCTAssertFalse(anchors[0].quote.contains("\n"))
    }

    /// A link that wraps an image across blank lines is three blocks on disk and
    /// one block after the reader joins them. The index must stay the index on
    /// disk, so a later block counts the joined blocks too.
    func testIndexCountsTheBlocksOfTheRawBody() {
        let markdown = """
        Intro paragraph.

        [

        ![a picture](assets/a.png)

        ](https://example.com)

        After the picture.
        """
        // On disk the body holds five blocks: the intro, the `[` line, the
        // image, the `](url)` line, and the closing paragraph. The reader joins
        // the middle three into one. The joined block keeps the index of the
        // first block it covers, and the block after it counts all five.
        let anchors = ArticleDocument(markdown: markdown).anchors.anchors
        XCTAssertEqual(anchors.count, 3, "the reader shows three blocks")
        XCTAssertEqual(anchors.map(\.block), [0, 1, 4],
                       "the index stays an index into the raw body")
    }

    // ── Resolving a stored position ───────────────────────────────────────────

    func testRestoreUsesTheIndexWhenTheQuoteAgrees() {
        let document = document()
        let stored = document.anchors.anchors[2]
        XCTAssertEqual(
            document.blockToRestore(block: stored.block, quote: stored.quote, percent: stored.percent),
            2
        )
    }

    func testRestoreFindsTheQuoteWhenTheIndexMoved() {
        // The body gained a paragraph at the top, so block 2 now holds other
        // text. The quote still names the section heading.
        let document = ArticleDocument(markdown: "New first paragraph.\n\n" + body)
        XCTAssertEqual(
            document.blockToRestore(block: 2, quote: "A section", percent: 0.5),
            3
        )
    }

    func testRestoreFallsBackToProgress() {
        let document = document()
        // Neither the index nor the quote is in the article any more.
        let index = document.blockToRestore(block: 99, quote: "gone from the body", percent: 0.5)
        XCTAssertNotNil(index)
        XCTAssertLessThanOrEqual(document.anchors.anchors[index ?? 0].percent, 0.5)
    }

    func testQuotesAgreeWhenOneIsCutShorter() {
        XCTAssertTrue(ArticleAnchors.quotesAgree("First paragraph", "First paragraph of the article."))
        XCTAssertTrue(ArticleAnchors.quotesAgree("", ""))
        XCTAssertFalse(ArticleAnchors.quotesAgree("", "Some text"))
        XCTAssertFalse(ArticleAnchors.quotesAgree("Other text", "Some text"))
    }

    // ── Where a block sits in the rendered groups ──────────────────────────────

    func testEveryBlockHasAPlaceAmongTheGroups() {
        let document = document()
        XCTAssertEqual(document.blockCount, document.anchors.anchors.count)
        let groupIDs = Set(document.groups.map(\.id))
        for index in 0 ..< document.blockCount {
            let location = document.location(ofBlock: index)
            XCTAssertNotNil(location)
            XCTAssertTrue(groupIDs.contains(location?.groupID ?? ""))
        }
    }

    /// A figure is not foldable, so it forms its own group between two runs.
    func testAFigureSplitsTheRunsAndKeepsBlockOrder() {
        let markdown = """
        Before the picture.

        ![a picture](assets/a.png)

        After the picture.
        """
        let document = ArticleDocument(markdown: markdown)
        XCTAssertEqual(document.groups.count, 3)
        XCTAssertEqual(document.groups.map(\.firstBlock), [0, 1, 2])
        XCTAssertEqual(document.location(ofBlock: 2)?.indexInGroup, 0)
    }

    // ── Offsets inside one text run ───────────────────────────────────────────

    func testRunReportsWhereEachBlockStarts() {
        let theme = MarkdownTheme(font: .system, fontSize: .medium, width: .medium, lineHeight: .normal)
        let blocks = Array(Document(parsing: "Alpha one.\n\nBravo two.\n\nCharlie three.").children)
        let built = MarkdownTextRun.build(blocks, theme: theme)

        XCTAssertEqual(built.blockOffsets.count, 3)
        XCTAssertEqual(built.blockOffsets.first, 0)
        let text = built.attributed.string as NSString
        XCTAssertEqual(text.substring(from: built.blockOffsets[1]).hasPrefix("Bravo two."), true)
        XCTAssertEqual(text.substring(from: built.blockOffsets[2]).hasPrefix("Charlie three."), true)
    }
}
