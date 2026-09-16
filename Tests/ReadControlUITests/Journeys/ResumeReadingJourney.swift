// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Picking a long read back up where you left it. Open a long article, read part
/// way down, and confirm the two places that must agree: the `position.md` file
/// beside the article, and the reader itself when the article opens again.
///
/// The article is opened again two ways, because the reader reaches the tracker
/// by a different route each time (see `ArticleDetailView+Loading`): once from
/// the parse cache, and once from a cold launch, which parses the body again. A
/// reader that only handles one of the two stops recording for the rest of the
/// reading.
///
/// The journey reads well short of the end on purpose: reaching the end marks
/// the reading read, which clears the position (see `EndOfArticle`).
final class ResumeReadingJourney: UITestCase {
    func testTheReaderRecordsAndRestoresWhereYouStopped() throws {
        try launchApp(articles: [Self.longRead, Self.otherArticle])

        let firstStop = try readPartWayDown()
        let secondStop = try comeBackFromTheCache(after: firstStop)
        try relaunchAndKeepReading(after: secondStop)

        // Nothing here reached the end, thus the reading is still unread — the
        // reader would otherwise clear the position it just stored.
        XCTAssertTrue(waitForFrontmatter(id: Self.longReadId) { $0.readAt == nil },
                      "reading the middle of an article never marks it read")
        XCTAssertTrue(list.rowHasIndicator(Self.longReadId, label: "Unread"),
                      "the row keeps the unread dot while the reading is unfinished")
    }

    // ── Steps ─────────────────────────────────────────────────────────────────

    /// Open the long read for the first time and stop part way down. The stop
    /// lands on disk, anchored to a block of the body with the quote of that
    /// block beside it.
    private func readPartWayDown() throws -> PositionFile {
        list.open(Self.longReadId)
        XCTAssertEqual(reader.titleText, Self.longReadTitle)
        XCTAssertFalse(library.positionExists(id: Self.longReadId), "no position before reading")

        reader.scrollBody(times: 3)

        XCTAssertTrue(
            waitForPosition(id: Self.longReadId) { $0.block > 0 },
            "the reader recorded where the user stopped"
        )
        let stop = try XCTUnwrap(library.position(id: Self.longReadId))
        XCTAssertTrue(stop.quote.hasPrefix("Paragraph"),
                      "the anchor quotes the block at the top of the window: \(stop.quote)")
        XCTAssertTrue(stop.percent > 0 && stop.percent <= 1,
                      "progress inside the article: \(stop.percent)")
        return stop
    }

    /// Leave for another reading and come back — the reader shows this one from
    /// its parse cache. It must go back to the stored block, and keep recording
    /// from there.
    private func comeBackFromTheCache(after firstStop: PositionFile) throws -> PositionFile {
        list.open(Self.otherArticleId)
        XCTAssertEqual(reader.titleText, "A Short Note")

        list.open(Self.longReadId)
        XCTAssertEqual(reader.titleText, Self.longReadTitle)
        XCTAssertTrue(reader.waitForScrolledPastHeader(),
                      "the reader went back into the body, not to the top")

        reader.scrollBody(times: 2)
        XCTAssertTrue(
            waitForPosition(id: Self.longReadId) { $0.block > firstStop.block },
            "the reader kept recording after the reading was opened again "
                + describeStop(from: firstStop.block)
        )
        let stop = try XCTUnwrap(library.position(id: Self.longReadId))
        XCTAssertTrue(stop.percent > firstStop.percent, "progress moved on")
        return stop
    }

    /// Quit and open the reading again. The position is a file, thus it
    /// survives — and this is the other order, with the position in hand before
    /// the article renders.
    private func relaunchAndKeepReading(after secondStop: PositionFile) throws {
        relaunchApp()
        sidebar.select(.all)
        list.open(Self.longReadId)
        XCTAssertEqual(reader.titleText, Self.longReadTitle)
        XCTAssertTrue(reader.waitForScrolledPastHeader(),
                      "a cold open goes back into the body too")

        reader.scrollBody(times: 2)
        XCTAssertTrue(
            waitForPosition(id: Self.longReadId) { $0.block > secondStop.block },
            "the reader still records after a relaunch " + describeStop(from: secondStop.block)
        )
    }

    /// What the file holds now, for a failure that would otherwise only say the
    /// block did not move.
    private func describeStop(from previous: Int) -> String {
        let position = library.position(id: Self.longReadId)
        return "(was block \(previous), now \(String(describing: position?.block)), "
            + "readAt \(String(describing: library.frontmatter(id: Self.longReadId)?.readAt)))"
    }

    // ── Fixtures ──────────────────────────────────────────────────────────────
    // A library of its own, rather than the standard corpus: this journey needs
    // an article many screens tall, so the reader can stop well inside it
    // without ever reaching the end.

    private static let longReadId = Fixtures.id(300)
    private static let otherArticleId = Fixtures.id(301)
    private static let longReadTitle = "The Long Read"

    private static let longRead = ArticleFixture(
        id: longReadId,
        url: "https://example.com/long-read",
        title: longReadTitle,
        savedAt: Date(timeIntervalSince1970: 1_767_225_600),
        site: "example.com",
        excerpt: "A long article to stop in the middle of.",
        wordCount: 4000,
        lang: "en",
        body: longBody
    )

    /// Somewhere else to go, so returning to the long read comes from the cache.
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

    /// A heading and two hundred and forty paragraphs, each its own top-level
    /// block — so a block index names a paragraph, and the quote of the block the
    /// reader stopped at is easy to recognize.
    ///
    /// The article must stay many screens tall: the journey scrolls seven screens
    /// in all, and reaching the end would mark the reading read, which clears the
    /// very position the journey asserts.
    private static var longBody: String {
        let paragraphs = (1 ... 240).map { number in
            "Paragraph \(String(format: "%03d", number)) — local-first software "
                + "keeps every reading on your own disk, in a file you can open "
                + "with any editor, for as long as you keep it."
        }
        return "# \(longReadTitle)\n\n" + paragraphs.joined(separator: "\n\n") + "\n"
    }
}
