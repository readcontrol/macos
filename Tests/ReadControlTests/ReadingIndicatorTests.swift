// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The leading column of a reading row shows one of three things. These tests
/// pin the choice; the row view only renders what the choice says.
final class ReadingIndicatorTests: XCTestCase {
    func testUnreadWithoutAPositionShowsTheDot() {
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow()), .unread)
    }

    func testUnreadWithAPositionShowsTheRing() {
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow(progress: 0.63)), .progress(0.63))
    }

    func testAReadReadingShowsNothing() {
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow(read: true)), .none)
        XCTAssertEqual(
            ReadingIndicator.forRow(makeReadingRow(read: true, progress: 0.4)), .none,
            "a read reading shows nothing, even when it still holds a position"
        )
    }

    func testAPositionAtTheStartKeepsTheDot() {
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow(progress: 0)), .unread)
    }

    func testProgressNeverPassesOne() {
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow(progress: 1.4)), .progress(1))
    }

    func testTheLabelReadsTheProgress() {
        XCTAssertEqual(ReadingIndicator.progress(0.63).label, "63 percent read")
        XCTAssertEqual(ReadingIndicator.unread.label, "Unread")
        XCTAssertEqual(ReadingIndicator.none.label, "")
    }
}
