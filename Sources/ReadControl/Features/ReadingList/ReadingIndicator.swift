// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What the leading column of a reading row shows.
enum ReadingIndicator: Equatable {
    /// The reading is read. The column stays empty.
    case none
    /// The reading is unread and the user did not start it.
    case unread
    /// The reading is unread and the user stopped inside it, at this progress.
    case progress(Float)

    /// The indicator for a row. A read reading shows nothing, even when it
    /// still holds a reading position. A position at the very start counts as
    /// not started.
    static func forRow(_ row: ReadingRow) -> ReadingIndicator {
        if row.read {
            return .none
        }
        guard let progress = row.progress, progress > 0 else {
            return .unread
        }
        return .progress(min(progress, 1))
    }

    /// What VoiceOver reads for the column.
    var label: String {
        switch self {
        case .none: ""
        case .unread: "Unread"
        case let .progress(value): "\(Int((value * 100).rounded())) percent read"
        }
    }
}

/// The leading column of a reading row. It keeps a fixed width, so the title,
/// the site, and the excerpt of every row share one text column. The tokens
/// come from DESIGN.md.
struct ReadingIndicatorView: View {
    let indicator: ReadingIndicator

    private let columnWidth: CGFloat = 10
    private let dotSize: CGFloat = 7
    private let ringSize: CGFloat = 9
    private let ringStroke: CGFloat = 1.5

    var body: some View {
        ZStack {
            switch indicator {
            case .none:
                Color.clear
            case .unread:
                Circle()
                    .fill(.blue)
                    .frame(width: dotSize, height: dotSize)
            case let .progress(value):
                ring(value)
            }
        }
        .frame(width: columnWidth, height: ringSize)
        .padding(.top, 6)
        .accessibilityLabel(indicator.label)
    }

    /// The progress ring: a full track, and an arc that starts at the top and
    /// runs clockwise.
    private func ring(_ value: Float) -> some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: ringStroke)
            Circle()
                .trim(from: 0, to: CGFloat(value))
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: ringSize, height: ringSize)
    }
}
