// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Marks a block that is not part of a text run — a figure, a table, a code
/// block, or a list or quote that holds an image — with its position among the
/// article's blocks.
///
/// A text run reports its own blocks (see `ReaderTextView`). The other blocks are
/// SwiftUI views, which the reader cannot ask. The reader puts this marker behind
/// each of them, thus every block on screen can name itself.
struct BlockAnchorMarker: NSViewRepresentable {
    /// Position of the block among all top-level blocks of the article.
    let block: Int

    func makeNSView(context _: Context) -> BlockAnchorView {
        let view = BlockAnchorView()
        view.block = block
        return view
    }

    func updateNSView(_ view: BlockAnchorView, context _: Context) {
        view.block = block
    }
}

/// The view the marker puts behind a block. It draws nothing and takes no
/// clicks; it only carries the block number and its frame.
final class BlockAnchorView: NSView {
    var block: Int = 0

    /// Let every click through to the content above, and to the background that
    /// clears the text selection.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
