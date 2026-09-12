// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Records where the user stopped in an article, and goes back to that block
/// when the article opens again.
///
/// The reader gives this object the parsed document and the stored position.
/// `ReaderScrollProbe` tells it when the scroll is ready, and when the scroll
/// stops. The object then finds the block at the top of the window — a text run
/// answers through `ReaderTextView.block(at:)`, and every other block through the
/// `BlockAnchorView` behind it — and reports the anchor of that block.
///
/// The rules of the ticket: a restore never records, an anchor that did not
/// change writes nothing, and the start of the article means "no position" (the
/// core deletes the file when the block is 0).
@MainActor
final class ReaderPositionTracker {
    /// How many times the reader tries to reach the stored block. The blocks
    /// lay out lazily, thus the first try can land before the block exists.
    private static let restorePasses = 3
    /// The wait between two tries.
    private static let restoreStep: Duration = .milliseconds(80)

    /// Called with the anchor to store. The reader sends it to the core.
    var onRecord: (String, ArticleAnchors.Anchor) -> Void = { _, _ in }

    /// Called once, when the user reaches the end of the article. The reader
    /// marks the reading read.
    var onReachEnd: (String) -> Void = { _ in }

    private var readingID: String?
    private var document: ArticleDocument?
    /// The scroll the reader shows this article in, kept so a typography change
    /// can put the anchor block back at the top.
    private weak var scrollView: NSScrollView?
    /// True once the scroll offset moved, which only the user does. A window
    /// resize changes the size of the visible area, not the offset.
    private var userScrolled = false
    /// The offset at the last stop, to see whether the scroll moved.
    private var lastOffset: CGFloat?
    /// True once the reader reported the end, so it reports it one time only.
    private var reportedEnd = false
    /// The block to go to, until a restore reaches it.
    private var wanted: Int?
    /// The block of the last report, so an unchanged anchor writes nothing.
    private var lastRecorded: Int?
    /// True while a restore moves the scroll, so the move never records.
    private var isRestoring = false

    // ── Reader events ─────────────────────────────────────────────────────────

    /// The reader shows `document` for the reading `id`. `position` is what the
    /// core stored, or nil when the reading has none.
    func open(readingID id: String, document: ArticleDocument, position: ReadingPosition?) {
        readingID = id
        self.document = document
        lastRecorded = nil
        userScrolled = false
        lastOffset = nil
        reportedEnd = false
        isRestoring = position != nil
        wanted = position.flatMap {
            document.blockToRestore(block: $0.block, quote: $0.quote, percent: $0.percent)
        }
    }

    /// The scroll view is in the window. Go to the stored block, if there is one.
    func scrollReady(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        guard let wanted, wanted > 0 else {
            isRestoring = false
            return
        }
        Task { await restore(to: wanted, in: scrollView) }
    }

    /// The scroll stopped. Report the end of the article, or record the block
    /// at the top of the window.
    func scrollSettled(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        guard !isRestoring, let readingID, let document else { return }

        let offset = scrollView.contentView.bounds.origin.y
        if let lastOffset, offset != lastOffset {
            userScrolled = true
        }
        lastOffset = offset

        if !reportedEnd, reachedEnd(in: scrollView) {
            reportedEnd = true
            onReachEnd(readingID)
            return
        }

        guard let block = topBlock(in: scrollView), block != lastRecorded else { return }
        guard let anchor = document.anchors.anchor(at: block) else { return }
        lastRecorded = block
        onRecord(readingID, anchor)
    }

    /// Whether the end of the article stands in the window.
    private func reachedEnd(in scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        return EndOfArticle.reached(
            visibleBottom: scrollView.contentView.bounds.maxY,
            contentHeight: documentView.bounds.height,
            userScrolled: userScrolled
        )
    }

    /// The typography changed, so the text laid out again. Put the block the
    /// reader last saw back at the top of the window.
    func keepAnchor() {
        guard let scrollView, let block = lastRecorded ?? wanted, block > 0 else { return }
        Task { await restore(to: block, in: scrollView) }
    }

    // ── Restore ───────────────────────────────────────────────────────────────

    /// Move the scroll so `block` sits at the top of the window. The blocks lay
    /// out lazily, thus this tries again a few times: the first pass goes near
    /// the block by its progress, and each later pass corrects with the real
    /// position of the block.
    private func restore(to block: Int, in scrollView: NSScrollView) async {
        isRestoring = true
        defer {
            isRestoring = false
            wanted = nil
            lastRecorded = block
        }
        for pass in 0 ..< Self.restorePasses {
            if let top = documentTop(ofBlock: block, in: scrollView) {
                scroll(scrollView, to: top)
            } else if pass == 0, let percent = document?.anchors.anchor(at: block)?.percent {
                scroll(scrollView, to: approximateTop(percent: percent, in: scrollView))
            }
            try? await Task.sleep(for: Self.restoreStep)
        }
    }

    /// Move the scroll to `top`, inside the range the document allows.
    private func scroll(_ scrollView: NSScrollView, to top: CGFloat) {
        guard let documentView = scrollView.documentView else { return }
        let maximum = max(documentView.bounds.height - scrollView.contentView.bounds.height, 0)
        let clamped = min(max(top, 0), maximum)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Where the article is at `percent` of its height. The reader uses it for
    /// the first pass, to bring the block it wants into the laid-out area.
    private func approximateTop(percent: Float, in scrollView: NSScrollView) -> CGFloat {
        let height = scrollView.documentView?.bounds.height ?? 0
        return height * CGFloat(percent)
    }

    // ── Reading the scroll ────────────────────────────────────────────────────

    /// The block at the top of the visible area.
    private func topBlock(in scrollView: NSScrollView) -> Int? {
        guard let documentView = scrollView.documentView else { return nil }
        let top = scrollView.contentView.bounds.origin.y
        var best: Int?
        for case let (view, frame) in anchorViews(in: documentView) where frame.minY <= top + 1 {
            if let textView = view as? ReaderTextView {
                let point = CGPoint(x: 2, y: top - frame.minY)
                best = textView.block(at: point) ?? best
            } else if let marker = view as? BlockAnchorView {
                best = marker.block
            }
        }
        return best
    }

    /// Where the block starts, in the coordinates of the document view.
    private func documentTop(ofBlock block: Int, in scrollView: NSScrollView) -> CGFloat? {
        guard let documentView = scrollView.documentView else { return nil }
        for (view, frame) in anchorViews(in: documentView) {
            if let textView = view as? ReaderTextView, let local = textView.top(ofBlock: block) {
                return frame.minY + local
            }
            if let marker = view as? BlockAnchorView, marker.block == block {
                return frame.minY
            }
        }
        return nil
    }

    /// Every view that can name a block, with its frame in the document view.
    /// The list keeps the order of the article, because the views sit in that
    /// order in the tree.
    private func anchorViews(in documentView: NSView) -> [(NSView, CGRect)] {
        var found: [(NSView, CGRect)] = []
        func walk(_ view: NSView) {
            if view is ReaderTextView || view is BlockAnchorView {
                found.append((view, view.convert(view.bounds, to: documentView)))
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(documentView)
        return found.sorted { $0.1.minY < $1.1.minY }
    }
}
