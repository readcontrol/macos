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
@Observable
final class ReaderPositionTracker {
    /// The maximum number of tries to reach the stored block. The blocks lay
    /// out lazily, thus the first try can land before the block exists. A
    /// restore stops early when two tries find the block at the same place.
    private static let restorePasses = 12
    /// The wait between two tries: about one frame.
    private static let restoreStep: Duration = .milliseconds(16)
    /// The longest time the article stays hidden, if a restore never starts.
    private static let revealTimeout: Duration = .seconds(1)

    /// True while the reader goes to the stored block of a reading it just
    /// opened. The reader hides the article for that time, thus the user sees
    /// the article at its position and never sees the scroll move.
    private(set) var hidesArticle = false

    /// Called with the anchor to store. The reader sends it to the core.
    @ObservationIgnored var onRecord: (String, ArticleAnchors.Anchor) -> Void = { _, _ in }

    /// Called once, when the user reaches the end of the article. The reader
    /// marks the reading read.
    @ObservationIgnored var onReachEnd: (String) -> Void = { _ in }

    @ObservationIgnored private var readingID: String?
    @ObservationIgnored private var document: ArticleDocument?
    /// The scroll the reader shows this article in, kept so a typography change
    /// can put the anchor block back at the top.
    @ObservationIgnored private weak var scrollView: NSScrollView?
    /// The reading `scrollView` belongs to. The reader builds one scroll view
    /// for each reading, and reports it before or after `open` (see
    /// `startRestoreIfReady`), thus the tracker keeps the id beside it and never
    /// scrolls the reading the reader showed before this one.
    @ObservationIgnored private var scrollViewReadingID: String?
    /// True once the scroll offset moved, which only the user does. A window
    /// resize changes the size of the visible area, not the offset.
    @ObservationIgnored private var userScrolled = false
    /// The offset the reading started at: the top, or the block a restore
    /// went to. A stop at another offset means the user moved the scroll.
    @ObservationIgnored private var startOffset: CGFloat?
    /// Changes at each `open`, so a restore of the reading before this one
    /// stops and changes nothing.
    @ObservationIgnored private var generation = 0
    /// True once the reader reported the end, so it reports it one time only.
    @ObservationIgnored private var reportedEnd = false
    /// The block to go to, until a restore reaches it.
    @ObservationIgnored private var wanted: Int?
    /// The block of the last report, so an unchanged anchor writes nothing.
    @ObservationIgnored private var lastRecorded: Int?
    /// True while a restore moves the scroll, so the move never records.
    @ObservationIgnored private var isRestoring = false

    // ── Reader events ─────────────────────────────────────────────────────────

    /// The reader shows `document` for the reading `id`. `position` is what the
    /// core stored, or nil when the reading has none.
    func open(readingID id: String, document: ArticleDocument, position: ReadingPosition?) {
        readingID = id
        self.document = document
        generation += 1
        lastRecorded = nil
        userScrolled = false
        startOffset = nil
        reportedEnd = false
        wanted = position.flatMap {
            document.blockToRestore(block: $0.block, quote: $0.quote, percent: $0.percent)
        }
        // Hold every report until the restore ran, so the scroll the restore
        // itself makes never counts as a place the user stopped.
        isRestoring = (wanted ?? 0) > 0
        hidesArticle = isRestoring
        if hidesArticle {
            let opened = generation
            Task {
                try? await Task.sleep(for: Self.revealTimeout)
                if generation == opened { hidesArticle = false }
            }
        }
        startRestoreIfReady()
    }

    /// The body of the open reading changed on disk. Keep the scroll where it
    /// is, and name the blocks of the new body from now on.
    func replaceDocument(_ document: ArticleDocument) {
        self.document = document
        lastRecorded = nil
    }

    /// The scroll view of the reading `id` is in the window.
    func scrollReady(_ scrollView: NSScrollView, for id: String) {
        self.scrollView = scrollView
        scrollViewReadingID = id
        startRestoreIfReady()
    }

    /// Go to the stored block, once the reading and its own scroll view are
    /// both here.
    ///
    /// The reader calls `open` before the article renders, thus `open` usually
    /// comes first. The tracker also accepts the other order. Each one tries,
    /// and the second one starts the restore.
    private func startRestoreIfReady() {
        guard let block = wanted, block > 0 else {
            isRestoring = false
            hidesArticle = false
            if startOffset == nil, let scrollView = currentScrollView {
                startOffset = scrollView.contentView.bounds.origin.y
            }
            return
        }
        guard let scrollView = currentScrollView else { return }
        wanted = nil
        isRestoring = true
        let started = generation
        Task { await restore(to: block, in: scrollView, generation: started) }
    }

    /// The scroll of the reading now open. Nil while the tracker still holds
    /// the scroll view of the reading before it.
    private var currentScrollView: NSScrollView? {
        guard let readingID, scrollViewReadingID == readingID else { return nil }
        return scrollView
    }

    /// The scroll of the reading `id` stopped. Report the end of the article, or
    /// record the block at the top of the window. A stop that the reader sends
    /// for the reading before this one names another article's blocks, thus the
    /// tracker drops it.
    func scrollSettled(_ scrollView: NSScrollView, for id: String) {
        guard readingID == id else { return }
        self.scrollView = scrollView
        scrollViewReadingID = id
        guard !isRestoring, let readingID, let document else { return }

        let offset = scrollView.contentView.bounds.origin.y
        if let startOffset {
            if offset != startOffset { userScrolled = true }
        } else {
            startOffset = offset
        }

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
        guard let scrollView = currentScrollView, let block = lastRecorded ?? wanted, block > 0 else {
            return
        }
        isRestoring = true
        let started = generation
        Task { await restore(to: block, in: scrollView, generation: started) }
    }

    // ── Restore ───────────────────────────────────────────────────────────────

    /// Move the scroll so `block` sits at the top of the window. The blocks lay
    /// out lazily, thus this tries again: the first pass goes near the block by
    /// its progress, and each later pass corrects with the real position of the
    /// block. The restore stops when two passes find the block at the same
    /// place, or when the reader opened another reading.
    /// `started` is the generation when the restore was asked for.
    private func restore(to block: Int, in scrollView: NSScrollView, generation started: Int) async {
        isRestoring = true
        var previousTop: CGFloat?
        for pass in 0 ..< Self.restorePasses {
            guard generation == started else { return }
            scrollView.layoutSubtreeIfNeeded()
            if let top = documentTop(ofBlock: block, in: scrollView) {
                scroll(scrollView, to: top)
                if let previousTop, abs(top - previousTop) < 1 { break }
                previousTop = top
            } else if pass == 0, let percent = document?.anchors.anchor(at: block)?.percent {
                scroll(scrollView, to: approximateTop(percent: percent, in: scrollView))
            }
            try? await Task.sleep(for: Self.restoreStep)
        }
        guard generation == started else { return }
        isRestoring = false
        wanted = nil
        lastRecorded = block
        startOffset = scrollView.contentView.bounds.origin.y
        hidesArticle = false
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
