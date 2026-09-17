// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import XCTest

/// The tracker goes back to the stored block, and from then on records the
/// block at the top of the window.
///
/// The reader calls `open` before the article renders, thus `open` usually
/// comes before `scrollReady`. The tracker accepts both orders, and these tests
/// drive both, because a tracker that waits for one of them records nothing for
/// the rest of the reading.
@MainActor
final class ReaderPositionTrackerTests: XCTestCase {
    private let body = """
    # Title

    First paragraph of the article.

    ## A section

    Second paragraph, further down.
    """

    /// The stored position: the second block, with the quote the reader wrote.
    private var storedPosition: ReadingPosition {
        ReadingPosition(block: 1, quote: "First paragraph of the article.",
                        percent: 0.2, offset: 0, changedAt: "2026-08-18T10:12:04.881Z")
    }

    // ── Both orders ───────────────────────────────────────────────────────────

    func testRestoresAndRecordsWhenTheScrollArrivesBeforeTheReading() async throws {
        let tracker = ReaderPositionTracker()
        var recorded: [ArticleAnchors.Anchor] = []
        tracker.onRecord = { _, anchor, _ in recorded.append(anchor) }
        let scrollView = makeScrollView()

        // The cached-parse order: the article is on screen, so its scroll view
        // reports, and only then does the position file come back.
        tracker.scrollReady(scrollView, for: "reading")
        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: storedPosition)
        try await waitForRestore()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 300,
                       "the reader must go back to the stored block")

        scroll(scrollView, to: 900)
        tracker.scrollSettled(scrollView, for: "reading")

        XCTAssertEqual(recorded.map(\.block), [3],
                       "the reader must record where the user stopped")
    }

    func testRestoresAndRecordsWhenTheReadingArrivesBeforeTheScroll() async throws {
        let tracker = ReaderPositionTracker()
        var recorded: [ArticleAnchors.Anchor] = []
        tracker.onRecord = { _, anchor, _ in recorded.append(anchor) }
        let scrollView = makeScrollView()

        // The first-open order: the position is in hand before the article
        // renders, thus the reading comes first.
        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: storedPosition)
        tracker.scrollReady(scrollView, for: "reading")
        try await waitForRestore()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 300)

        scroll(scrollView, to: 900)
        tracker.scrollSettled(scrollView, for: "reading")

        XCTAssertEqual(recorded.map(\.block), [3])
    }

    // ── Rules of the tracker ──────────────────────────────────────────────────

    func testARestoreNeverRecords() async throws {
        let tracker = ReaderPositionTracker()
        var recorded: [ArticleAnchors.Anchor] = []
        tracker.onRecord = { _, anchor, _ in recorded.append(anchor) }
        let scrollView = makeScrollView()

        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: storedPosition)
        tracker.scrollReady(scrollView, for: "reading")
        // The scroll the restore makes stops like any other.
        tracker.scrollSettled(scrollView, for: "reading")
        try await waitForRestore()

        XCTAssertEqual(recorded, [], "the move the reader made must not record")
    }

    func testAReadingWithoutAPositionRecordsFromTheStart() {
        let tracker = ReaderPositionTracker()
        var recorded: [ArticleAnchors.Anchor] = []
        tracker.onRecord = { _, anchor, _ in recorded.append(anchor) }
        let scrollView = makeScrollView()

        tracker.scrollReady(scrollView, for: "reading")
        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: nil)
        scroll(scrollView, to: 600)
        tracker.scrollSettled(scrollView, for: "reading")

        XCTAssertEqual(recorded.map(\.block), [2])
    }

    func testAStopOfThePreviousReadingIsDropped() {
        let tracker = ReaderPositionTracker()
        var recorded: [(id: String, block: Int)] = []
        tracker.onRecord = { id, anchor, _ in recorded.append((id, anchor.block)) }
        let previous = makeScrollView()

        tracker.open(readingID: "second", document: ArticleDocument(markdown: body),
                     position: nil)
        // The scroll view of the reading before this one stops late. Its blocks
        // are another article's, thus nothing may be written for "second".
        scroll(previous, to: 600)
        tracker.scrollSettled(previous, for: "first")

        XCTAssertEqual(recorded.count, 0)
    }

    // ── End of the article ────────────────────────────────────────────────────

    func testTheFirstStopAtTheEndMarksTheReadingRead() {
        let tracker = ReaderPositionTracker()
        var ended: [String] = []
        tracker.onReachEnd = { ended.append($0) }
        let scrollView = makeScrollView()

        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: nil)
        tracker.scrollReady(scrollView, for: "reading")
        // One scroll from the top to the end, thus one stop only.
        scroll(scrollView, to: 1000)
        tracker.scrollSettled(scrollView, for: "reading")

        XCTAssertEqual(ended, ["reading"], "a stop at the end must mark the reading read")
    }

    func testAnArticleThatFitsTheWindowIsNotMarkedRead() {
        let tracker = ReaderPositionTracker()
        var ended: [String] = []
        tracker.onReachEnd = { ended.append($0) }
        let scrollView = makeScrollView(height: 150)

        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: nil)
        tracker.scrollReady(scrollView, for: "reading")
        tracker.scrollSettled(scrollView, for: "reading")

        XCTAssertEqual(ended, [], "the user did not move the scroll")
    }

    // ── Hiding during a restore ───────────────────────────────────────────────

    func testTheArticleIsHiddenUntilTheRestoreReachesTheBlock() async throws {
        let tracker = ReaderPositionTracker()
        let scrollView = makeScrollView()

        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: storedPosition)
        XCTAssertTrue(tracker.hidesArticle, "the article must not show at the top first")

        tracker.scrollReady(scrollView, for: "reading")
        try await waitForRestore()

        XCTAssertFalse(tracker.hidesArticle)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 300)
    }

    func testAReadingWithoutAPositionIsNeverHidden() {
        let tracker = ReaderPositionTracker()
        tracker.open(readingID: "reading", document: ArticleDocument(markdown: body),
                     position: nil)
        XCTAssertFalse(tracker.hidesArticle)
    }

    func testARestoreOfThePreviousReadingChangesNothing() async throws {
        let tracker = ReaderPositionTracker()
        let previous = makeScrollView()
        let next = makeScrollView()

        tracker.open(readingID: "first", document: ArticleDocument(markdown: body),
                     position: storedPosition)
        tracker.scrollReady(previous, for: "first")
        // The user opens the next reading while the first restore still runs.
        tracker.open(readingID: "second", document: ArticleDocument(markdown: body),
                     position: storedPosition)
        try await waitForRestore()

        XCTAssertTrue(tracker.hidesArticle,
                      "the old restore must not show the next reading before its own restore")
        tracker.scrollReady(next, for: "second")
        try await waitForRestore()
        XCTAssertFalse(tracker.hidesArticle)
        XCTAssertEqual(next.contentView.bounds.origin.y, 300)
    }

    // ── Fixtures ──────────────────────────────────────────────────────────────

    /// Long enough for a restore to finish (see `restorePasses`).
    private func waitForRestore() async throws {
        try await Task.sleep(for: .milliseconds(450))
    }

    /// A scroll view of four blocks, 300 points each, in a window 200 tall — so
    /// block 1 sits at 300 and block 3 at 900.
    private func makeScrollView(height: CGFloat = 1200) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        for block in 0 ..< 4 {
            let marker = BlockAnchorView(
                frame: NSRect(x: 0, y: CGFloat(block) * 300, width: 400, height: 300)
            )
            marker.block = block
            documentView.addSubview(marker)
        }
        scrollView.documentView = documentView
        return scrollView
    }

    private func scroll(_ scrollView: NSScrollView, to top: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The reader lays its content out from the top, as a scroll of text does.
    private final class FlippedView: NSView {
        override var isFlipped: Bool {
            true
        }
    }
}
