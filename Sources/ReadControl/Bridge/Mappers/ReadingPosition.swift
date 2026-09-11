// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the user stopped in a reading, in app language rather than the FFI
/// boundary type (see ADR 0001). The core owns the file this comes from; the
/// reader only reads a position and reports a new one.
struct ReadingPosition: Equatable, Sendable {
    /// 0-based index of the anchor block in the body.
    var block: Int
    /// The start of the anchor block, on one line.
    var quote: String
    /// How far the user read before the anchor block, from 0 to 1.
    var percent: Float
    /// UTC time of the last change. The library format calls the field `at`.
    var changedAt: String
}

extension ReadingPosition {
    /// Maps the FFI boundary record into the app's own value.
    init(_ position: FfiPosition) {
        block = Int(position.block)
        quote = position.quote
        percent = position.percent
        changedAt = position.at
    }
}
