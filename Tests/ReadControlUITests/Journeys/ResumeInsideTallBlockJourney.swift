// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Stopping *inside* a tall block — a long block quote (an image behaves the
/// same) — and coming back to the same place, not the top of the block.
///
/// The reader anchors a position to a block index, but a tall block covers many
/// screens, so a stop half way down it must record how far into the block it is
/// (`offset` in `position.md`). Without that, coming back snaps to the top of the
/// block — the jump the user sees on an article with an image or a quote. This
/// journey drives the whole path the fix added: the reader measures the offset,
/// the core writes it to `position.md`, and coming back reads it and lands in the
/// body rather than at the top.
final class ResumeInsideTallBlockJourney: UITestCase {
    func testStoppingInsideATallQuoteRecordsAndRestoresTheOffset() throws {
        try launchApp(articles: [Self.tallRead, Self.otherArticle])

        list.open(Self.tallReadId)
        XCTAssertEqual(reader.titleText, Self.tallReadTitle)

        // Stop part way down the quote. The quote is many screens tall, so one
        // scroll leaves the window top inside it, not past it.
        reader.scrollBody(times: 1)

        // The stop lands on the quote block (index 1), with an offset that says
        // how far into it the window top sits — the value the fix records.
        XCTAssertTrue(
            waitForPosition(id: Self.tallReadId) { $0.block == 1 && $0.offset > 0.05 },
            "a stop inside the quote records an offset into the block: "
                + String(describing: library.position(id: Self.tallReadId).map { ($0.block, $0.offset) })
        )
        let stop = try XCTUnwrap(library.position(id: Self.tallReadId))
        XCTAssertTrue(stop.quote.hasPrefix("Quote line"),
                      "the anchor names the quote block: \(stop.quote)")

        // Leave for another reading, then come back from the parse cache. The
        // reader must go back into the body — not to the top of the article — and
        // must keep the same anchor block and offset, since nothing moved.
        list.open(Self.otherArticleId)
        XCTAssertEqual(reader.titleText, "A Short Note")

        list.open(Self.tallReadId)
        XCTAssertEqual(reader.titleText, Self.tallReadTitle)
        XCTAssertTrue(reader.waitForScrolledPastHeader(),
                      "the reader went back into the quote, not to the top")

        let after = try XCTUnwrap(library.position(id: Self.tallReadId))
        XCTAssertEqual(after.block, 1, "coming back keeps the same anchor block")
        XCTAssertEqual(after.offset, stop.offset, accuracy: 0.1,
                       "coming back keeps the same place inside the block")
    }

    // ── Fixtures ──────────────────────────────────────────────────────────────

    private static let tallReadId = Fixtures.id(320)
    private static let otherArticleId = Fixtures.id(321)
    private static let tallReadTitle = "A Long Quotation"

    private static let tallRead = ArticleFixture(
        id: tallReadId,
        url: "https://example.com/long-quote",
        title: tallReadTitle,
        savedAt: Date(timeIntervalSince1970: 1_767_225_600),
        site: "example.com",
        excerpt: "An article that opens on a very tall quote.",
        wordCount: 4000,
        lang: "en",
        body: tallBody
    )

    /// Somewhere else to go, so returning to the tall read comes from the cache.
    private static let otherArticle = ArticleFixture(
        id: otherArticleId,
        url: "https://example.com/short-note",
        title: "A Short Note",
        savedAt: Date(timeIntervalSince1970: 1_767_139_200),
        site: "example.com",
        excerpt: "Somewhere else to look.",
        wordCount: 50,
        lang: "en"
    )

    /// A title, then one block quote of eighty lines — a single top-level block
    /// many screens tall, so the window top can sit well inside it — then many
    /// paragraphs, so the article is tall enough to scroll the quote's middle to
    /// the top without reaching the end (which would mark it read and clear the
    /// position).
    private static var tallBody: String {
        let quote = (1 ... 80)
            .map { "> Quote line \(String(format: "%02d", $0)) — files you own outlive the apps that made them." }
            .joined(separator: "\n")
        let paragraphs = (1 ... 80).map {
            "Paragraph \(String(format: "%03d", $0)) follows the quotation and keeps the article tall."
        }
        return "# \(tallReadTitle)\n\n" + quote + "\n\n" + paragraphs.joined(separator: "\n\n") + "\n"
    }
}
