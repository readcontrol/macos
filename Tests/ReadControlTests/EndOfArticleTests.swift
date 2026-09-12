// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Reaching the end of an article marks it read. These tests pin the rule: the
/// end must stand in the window, and the user must have moved the scroll.
final class EndOfArticleTests: XCTestCase {
    private let height: CGFloat = 1200

    func testTheEndInTheWindowAfterAScrollReachesTheEnd() {
        XCTAssertTrue(EndOfArticle.reached(visibleBottom: height, contentHeight: height,
                                           userScrolled: true))
    }

    func testAnArticleThatFitsWithoutAScrollDoesNotReachTheEnd() {
        // The whole article stands in the window from the first frame. Marking
        // it read would surprise the user.
        XCTAssertFalse(EndOfArticle.reached(visibleBottom: 800, contentHeight: 600,
                                            userScrolled: false))
    }

    func testTheMiddleOfAnArticleDoesNotReachTheEnd() {
        XCTAssertFalse(EndOfArticle.reached(visibleBottom: 700, contentHeight: height,
                                            userScrolled: true))
    }

    func testAScrollThatStopsJustShortStillReachesTheEnd() {
        XCTAssertTrue(EndOfArticle.reached(visibleBottom: height - EndOfArticle.tolerance,
                                           contentHeight: height, userScrolled: true))
    }

    func testAStopFurtherShortDoesNotReachTheEnd() {
        XCTAssertFalse(EndOfArticle.reached(visibleBottom: height - EndOfArticle.tolerance - 1,
                                            contentHeight: height, userScrolled: true))
    }

    func testContentWithNoHeightNeverReachesTheEnd() {
        XCTAssertFalse(EndOfArticle.reached(visibleBottom: 0, contentHeight: 0, userScrolled: true))
    }
}
