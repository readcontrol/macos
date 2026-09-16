// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Reading an article to its end. The reader marks the reading read, but the
/// user is still in the article: the reader keeps it open and the selection
/// stays on it. In the Unread view the row leaves the list, and the selection
/// does not move to the next unread reading.
final class FinishReadingJourney: UITestCase {
    func testReachingTheEndMarksReadAndKeepsTheArticleOpen() throws {
        try launchApp(articles: [Self.article, Self.nextArticle]) { options in
            options.pinnedDefaults["sortField"] = "savedAt"
            options.pinnedDefaults["sortAscending"] = "0"
        }
        sidebar.select(.unread)
        XCTAssertTrue(list.waitForRowCount(2), "both readings start unread")

        list.open(Self.articleId)
        XCTAssertEqual(reader.titleText, Self.articleTitle)

        reader.scrollBody(times: 12)

        XCTAssertTrue(waitForFrontmatter(id: Self.articleId) { $0.isRead },
                      "reaching the end marks the reading read on disk")
        XCTAssertTrue(list.row(Self.articleId).waitDisappears(),
                      "the read row leaves the Unread list")
        XCTAssertTrue(list.row(Self.nextArticleId).waitExists(),
                      "the other unread reading stays in the list")
        XCTAssertEqual(reader.titleText, Self.articleTitle,
                       "the reader keeps the finished article open, and does not move to the next one")

        // In the All view the finished reading keeps its row, without the dot.
        sidebar.select(.all)
        XCTAssertTrue(list.row(Self.articleId).waitExists(), "the read row is still in All")
        XCTAssertFalse(list.rowHasIndicator(Self.articleId, label: "Unread"),
                       "the row shows no unread dot")
    }

    // ── Fixtures ──────────────────────────────────────────────────────────────

    private static let articleId = Fixtures.id(310)
    private static let nextArticleId = Fixtures.id(311)
    private static let articleTitle = "An Article To Finish"

    /// A few screens tall: the journey must scroll to reach the end, because an
    /// article that fits the window is never marked read.
    private static let article = ArticleFixture(
        id: articleId,
        url: "https://example.com/finish",
        title: articleTitle,
        savedAt: Date(timeIntervalSince1970: 1_767_225_600),
        site: "example.com",
        excerpt: "An article to read to the end.",
        wordCount: 900,
        lang: "en",
        body: body
    )

    /// The next unread reading, where a selection that advanced would land.
    private static let nextArticle = ArticleFixture(
        id: nextArticleId,
        url: "https://example.com/next",
        title: "The Next One",
        savedAt: Date(timeIntervalSince1970: 1_767_139_200),
        site: "example.com",
        excerpt: "The next reading in the list.",
        wordCount: 50,
        lang: "en"
    )

    private static var body: String {
        let paragraphs = (1 ... 40).map { number in
            "Paragraph \(String(format: "%02d", number)) — local-first software "
                + "keeps every reading on your own disk, in a file you can open "
                + "with any editor, for as long as you keep it."
        }
        return "# \(articleTitle)\n\n" + paragraphs.joined(separator: "\n\n") + "\n"
    }
}
