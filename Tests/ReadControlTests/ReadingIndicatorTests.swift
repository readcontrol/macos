// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The leading column of a reading row shows the unread dot, or nothing. These
/// tests pin the choice; the row view only renders what the choice says.
final class ReadingIndicatorTests: XCTestCase {
    func testAnUnreadReadingShowsTheDot() {
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow()), .unread)
    }

    func testAReadReadingShowsNothing() {
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow(read: true)), .none)
    }

    func testAReadingPositionNeverChangesTheColumn() {
        // How far the user got is kept in the reading, not shown in the list.
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow(progress: 0.63)), .unread)
        XCTAssertEqual(ReadingIndicator.forRow(makeReadingRow(read: true, progress: 0.4)), .none)
    }

    func testTheLabelNamesTheState() {
        XCTAssertEqual(ReadingIndicator.unread.label, "Unread")
        XCTAssertEqual(ReadingIndicator.none.label, "")
    }
}
