// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Reopening the app opens the reading the user had open when they quit. The
/// reader opens it even when the list does not show it: on a page the list did
/// not load yet, or outside the view. When the reading is gone, the app opens
/// the first row, as on a first launch.
final class ReopenLastReadingJourney: UITestCase {
    func testReopenOpensTheLastReading() throws {
        try launchApp(articles: [Self.newer, Self.older])
        list.open(Self.older.id)
        XCTAssertEqual(reader.titleText, Self.older.title)

        relaunchApp { options in
            options.pinnedDefaults["activeView"] = SmartView.all.rawValue
        }

        XCTAssertTrue(list.waitForRowCount(2), "the list shows both readings")
        XCTAssertEqual(reader.titleText, Self.older.title,
                       "the reader opens the last reading, not the first row")
    }

    func testReopenOpensTheLastReadingOnALaterPage() throws {
        // 120 readings, newest first: index 0 is the last row, on the second
        // page of 100.
        let reading = Fixtures.id(0)
        try launchApp(articles: Fixtures.bulkCorpus())
        XCTAssertTrue(list.scrollToRow(reading, timeout: 20), "scroll loads the second page")
        // Scroll to the bottom, so the last row is in the window and can take a click.
        for _ in 0 ..< 3 {
            list.scrollDown()
        }
        list.open(reading)
        XCTAssertEqual(reader.titleText, "Bulk Article 000")

        relaunchApp { options in
            options.pinnedDefaults["activeView"] = SmartView.all.rawValue
        }

        XCTAssertTrue(list.waitForRowCount(100), "the list loads the first page only")
        XCTAssertFalse(list.orderedRowIds.contains(reading), "the reading is not on the first page")
        XCTAssertEqual(reader.titleText, "Bulk Article 000", "the reader still opens the last reading")
    }

    func testReopenOpensTheLastReadingOutsideTheView() throws {
        try launchApp(articles: [Self.newer, Self.older])
        list.open(Self.older.id)
        XCTAssertEqual(reader.titleText, Self.older.title)

        // The older reading is read, thus the Unread view does not list it.
        relaunchApp { options in
            options.pinnedDefaults["activeView"] = SmartView.unread.rawValue
        }

        XCTAssertTrue(list.waitForRowCount(1), "Unread lists the newer reading only")
        XCTAssertTrue(list.row(Self.older.id).waitDisappears(), "the read reading is not listed")
        XCTAssertEqual(reader.titleText, Self.older.title, "the reader still opens the last reading")
    }

    func testReopenAfterTheLastReadingWasDeletedOpensTheFirstRow() throws {
        try launchApp(articles: [Self.newer, Self.older])
        list.open(Self.older.id)
        XCTAssertEqual(reader.titleText, Self.older.title)

        // Another device deletes the reading while the app is closed.
        app.terminate()
        try library.deleteArticle(id: Self.older.id)

        relaunchApp { options in
            options.pinnedDefaults["activeView"] = SmartView.all.rawValue
        }

        XCTAssertTrue(list.waitForRowCount(1), "the deleted reading is gone from the list")
        XCTAssertEqual(reader.titleText, Self.newer.title, "the reader opens the first row")
    }

    // ── Fixtures ──────────────────────────────────────────────────────────────

    private static let newer = ArticleFixture(
        id: Fixtures.id(320),
        url: "https://example.com/newer",
        title: "The Newer Reading",
        savedAt: Date(timeIntervalSince1970: 1_767_225_600),
        site: "example.com",
        wordCount: 20
    )

    /// Read, and saved first: it is never the first row, and Unread does not list it.
    private static let older = ArticleFixture(
        id: Fixtures.id(321),
        url: "https://example.com/older",
        title: "The Older Reading",
        savedAt: Date(timeIntervalSince1970: 1_767_139_200),
        readAt: Date(timeIntervalSince1970: 1_767_200_000),
        site: "example.com",
        wordCount: 20
    )
}
