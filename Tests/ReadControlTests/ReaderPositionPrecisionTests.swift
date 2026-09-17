// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Markdown
import XCTest

/// Round-trips a reading position through a **real** laid-out text run — short
/// paragraphs around one tall block quote — to measure how close the reader
/// comes back to where the user stopped.
///
/// `ReaderPositionTrackerTests` uses equal-height marker views, so it can only
/// stop at block boundaries and never shows the error a user hits inside a tall
/// block. Here the run is rendered with the same `MarkdownTextRun` the reader
/// uses, so a stop can land in the middle of the quote — the case the user
/// reported as imprecise.
@MainActor
final class ReaderPositionPrecisionTests: XCTestCase {
    /// Five short paragraphs, a ten-line block quote (one tall block), then five
    /// more short paragraphs. The quote is a single top-level block many lines
    /// tall, so stopping inside it is stopping in the middle of one block.
    private let markdown: String = {
        let intro = (1 ... 5).map { "Intro paragraph number \($0) sits above the quote." }
        let quoteLines = (1 ... 10).map { "> Quote line \($0) — plain files outlive the apps that made them." }
        // Many paragraphs below, so the article is tall enough to scroll the
        // quote's middle to the top of the window (short bodies clamp the scroll).
        let outro = (1 ... 40).map { "Outro paragraph number \($0) sits below the quote." }
        return (["# Title"] + intro + ["\n" + quoteLines.joined(separator: "\n")] + outro)
            .joined(separator: "\n\n") + "\n"
    }()

    /// The block index of the block quote among the article's top-level blocks:
    /// `# Title` (0), five intro paragraphs (1–5), then the quote (6).
    private let quoteBlock = 6

    func testComingBackLandsWhereYouStoppedInsideATallQuote() async throws {
        let document = ArticleDocument(markdown: markdown)
        let scrollView = makeRenderedScrollView(document: document)

        // Stop 150 points into the tall quote — well past its first line.
        let quoteTop = try XCTUnwrap(documentTop(ofBlock: quoteBlock, in: scrollView))
        let stopOffset = quoteTop + 150
        scroll(scrollView, to: stopOffset)

        // Record where the user stopped.
        let recorder = ReaderPositionTracker()
        var recorded: (anchor: ArticleAnchors.Anchor, offset: Float)?
        recorder.onRecord = { _, anchor, offset in recorded = (anchor, offset) }
        recorder.open(readingID: "reading", document: document, position: nil)
        recorder.scrollReady(scrollView, for: "reading")
        recorder.scrollSettled(scrollView, for: "reading")

        let stop = try XCTUnwrap(recorded, "the reader recorded nothing")
        XCTAssertEqual(stop.anchor.block, quoteBlock, "the anchor names the quote block")
        XCTAssertGreaterThan(stop.offset, 0, "the stop is inside the block, not at its top")

        // Come back to the article on a fresh scroll view, from the stored anchor.
        let reopened = makeRenderedScrollView(document: document)
        let restorer = ReaderPositionTracker()
        restorer.open(
            readingID: "reading",
            document: document,
            position: ReadingPosition(block: stop.anchor.block, quote: stop.anchor.quote,
                                      percent: stop.anchor.percent, offset: stop.offset,
                                      changedAt: "2026-09-17T00:00:00.000Z")
        )
        restorer.scrollReady(reopened, for: "reading")
        try await waitForRestore()

        let landed = reopened.contentView.bounds.origin.y
        XCTAssertEqual(landed, stopOffset, accuracy: 24,
                       "coming back must land where the user stopped, not snap to the top of the quote "
                           + "(stopped at \(stopOffset), landed at \(landed))")
    }

    // ── Rendering a real run into a scroll view ─────────────────────────────────

    /// Lay the document's single text run out into a `ReaderTextView` inside a
    /// flipped scroll view, exactly as `MarkdownDocumentView` would — so the
    /// tracker reads real block positions.
    private func makeRenderedScrollView(document: ArticleDocument) -> NSScrollView {
        let theme = MarkdownTheme(font: .system, fontSize: .medium, width: .medium, lineHeight: .normal)
        let width: CGFloat = 600

        let blocks = document.groups.compactMap { group -> [Markup]? in
            if case let .textRun(_, blocks, _) = group {
                return blocks
            }
            return nil
        }.first ?? []
        let run = MarkdownTextRun.build(blocks, theme: theme)

        let textView = ReaderTextView.make()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.blockOffsets = run.blockOffsets
        textView.firstBlock = 0
        textView.textStorage?.setAttributedString(run.attributed)
        textView.baseAttributed = run.attributed
        textView.setFrameSize(NSSize(width: width, height: 10))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let height = ceil(textView.layoutManager!.usedRect(for: textView.textContainer!).height)
        textView.setFrameSize(NSSize(width: width, height: height))
        textView.frame.origin = .zero

        let documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        documentView.addSubview(textView)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        scrollView.documentView = documentView
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    /// The document-view Y where `block` starts, found the way the tracker finds
    /// it (walking the text view of the run).
    private func documentTop(ofBlock block: Int, in scrollView: NSScrollView) -> CGFloat? {
        guard let documentView = scrollView.documentView else { return nil }
        for view in documentView.subviews {
            if let textView = view as? ReaderTextView, let local = textView.top(ofBlock: block) {
                return textView.frame.minY + local
            }
        }
        return nil
    }

    private func waitForRestore() async throws {
        try await Task.sleep(for: .milliseconds(450))
    }

    private func scroll(_ scrollView: NSScrollView, to top: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool {
            true
        }
    }
}
