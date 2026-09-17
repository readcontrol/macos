// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the user stopped in a reading, in app language rather than the FFI
/// boundary type (see ADR 0001). The core owns the file this comes from; the
/// reader only reads a position and reports a new one.
struct ReadingPosition: Equatable, Sendable {
    /// 0-based index of the anchor block in the body.
    var block: Int
    var quote: String
    var percent: Float
    /// How far into the anchor block the stop is, from 0.0 to 1.0. 0.0 is the
    /// top of the block. The reader lands inside the block, and not at its top.
    var offset: Float
    /// The library format calls this field `at`.
    var changedAt: String
}

extension ReadingPosition {
    /// Maps the FFI boundary record into the app's own value.
    init(_ position: FfiPosition) {
        block = Int(position.block)
        quote = position.quote
        percent = position.percent
        offset = position.offset
        changedAt = position.at
    }
}
