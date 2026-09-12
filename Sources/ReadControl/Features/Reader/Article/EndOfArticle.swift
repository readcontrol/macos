// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The rule for "the user reached the end of the article".
///
/// The reader marks an article read when its end comes into view, but only
/// after the user moved the scroll at least one time. A short article stands in
/// the window from the first frame, and marking that read would surprise the
/// user.
enum EndOfArticle {
    /// How near the bottom counts as the end. A scroll can stop a few points
    /// short while the last line already stands in the window.
    static let tolerance: CGFloat = 2

    /// Whether the reader reached the end of the article.
    ///
    /// - Parameters:
    ///   - visibleBottom: the bottom of the visible area, in the coordinates of
    ///     the scrolled content.
    ///   - contentHeight: the height of the whole content.
    ///   - userScrolled: whether the user moved the scroll in this session.
    static func reached(visibleBottom: CGFloat, contentHeight: CGFloat, userScrolled: Bool) -> Bool {
        guard userScrolled, contentHeight > 0 else { return false }
        return visibleBottom >= contentHeight - tolerance
    }
}
