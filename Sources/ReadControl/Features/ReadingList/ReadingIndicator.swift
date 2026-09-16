// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What the leading column of a reading row shows.
///
/// How far into a reading the user got is kept in the reading's `position.md`
/// and in the index, but the list does not show it: the column says whether a
/// reading is waiting, and nothing more.
enum ReadingIndicator: Equatable {
    /// The reading is read. The column stays empty.
    case none
    /// The reading is unread.
    case unread

    /// The indicator for a row.
    static func forRow(_ row: ReadingRow) -> ReadingIndicator {
        row.read ? .none : .unread
    }

    /// What VoiceOver reads for the column.
    var label: String {
        switch self {
        case .none: ""
        case .unread: "Unread"
        }
    }
}

/// The leading column of a reading row. It keeps a fixed width, so the title,
/// the site, and the excerpt of every row share one text column. The tokens
/// come from DESIGN.md.
struct ReadingIndicatorView: View {
    let indicator: ReadingIndicator

    private let columnWidth: CGFloat = 10
    private let columnHeight: CGFloat = 9
    private let dotSize: CGFloat = 7

    var body: some View {
        ZStack {
            switch indicator {
            case .none:
                Color.clear
            case .unread:
                Circle()
                    .fill(.blue)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: columnWidth, height: columnHeight)
        .padding(.top, 6)
        .accessibilityLabel(indicator.label)
    }
}
