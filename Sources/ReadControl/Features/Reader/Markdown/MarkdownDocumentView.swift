// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Markdown
import SwiftUI

// `ArticleDocument` — the parsed structure this view renders — lives in
// `Features/Reader/Article/ArticleDocument.swift`.

/// Native reader: renders a pre-parsed `ArticleDocument` as a SwiftUI view tree.
/// Replaces the `WKWebView`-based `MarkdownWebView`. Light/Dark adapt
/// automatically via semantic colors (appearance is applied app-wide in
/// `ReadControlApp`), and links open in the system browser.
struct MarkdownDocumentView<Header: View, Footer: View>: View {
    let document: ArticleDocument
    /// The reading's own folder URL, against which its relative asset links
    /// (`assets/<file>`) resolve. See `AssetImageLoader.readingFolderURL`.
    let assetBaseURL: URL?
    var font: ReaderFont = .system
    var fontSize: ReaderFontSize = .medium
    var width: ReaderWidth = .medium
    var lineHeight: ReaderLineHeight = .normal
    /// Verbatim text of the reading's highlights; each occurrence is tinted.
    var highlights: [String] = []
    /// Called with the selected text when the user highlights a passage.
    var onHighlight: (String) -> Void = { _ in }
    /// The scroll view is in the window, so the reader can go to a stored
    /// reading position (see `ReaderScrollProbe`).
    var onScrollReady: (NSScrollView) -> Void = { _ in }
    /// The scroll stopped, so the reader can record where the user stopped.
    var onScrollSettle: (NSScrollView) -> Void = { _ in }
    /// Leading content rendered inside the scroll, before the article body.
    @ViewBuilder var header: () -> Header
    /// Trailing content rendered inside the scroll, after the article body — so
    /// it comes into view only when the reader reaches the end of the article.
    @ViewBuilder var footer: () -> Footer

    init(document: ArticleDocument, assetBaseURL: URL?,
         font: ReaderFont = .system, fontSize: ReaderFontSize = .medium,
         width: ReaderWidth = .medium, lineHeight: ReaderLineHeight = .normal,
         highlights: [String] = [], onHighlight: @escaping (String) -> Void = { _ in },
         onScrollReady: @escaping (NSScrollView) -> Void = { _ in },
         onScrollSettle: @escaping (NSScrollView) -> Void = { _ in },
         @ViewBuilder header: @escaping () -> Header = { EmptyView() },
         @ViewBuilder footer: @escaping () -> Footer = { EmptyView() })
    {
        self.document = document
        self.assetBaseURL = assetBaseURL
        self.font = font
        self.fontSize = fontSize
        self.width = width
        self.lineHeight = lineHeight
        self.highlights = highlights
        self.onHighlight = onHighlight
        self.onScrollReady = onScrollReady
        self.onScrollSettle = onScrollSettle
        self.header = header
        self.footer = footer
    }

    private var theme: MarkdownTheme {
        MarkdownTheme(font: font, fontSize: fontSize, width: width, lineHeight: lineHeight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Gives the reader the scroll view, which macOS 14 SwiftUI does
                // not expose. It draws nothing.
                ReaderScrollProbe(onReady: onScrollReady, onSettle: onScrollSettle)
                    .frame(width: 0, height: 0)
                header()
                LazyVStack(alignment: .leading, spacing: theme.blockSpacing) {
                    ForEach(document.groups) { group in
                        switch group {
                        case let .textRun(_, blocks, firstBlock):
                            textRun(blocks: blocks, firstBlock: firstBlock)
                        case let .other(item, block):
                            MarkdownBlockView(block: item.markup, theme: theme, assetBaseURL: assetBaseURL,
                                              highlights: highlights, onHighlight: onHighlight)
                                .background(BlockAnchorMarker(block: block))
                        }
                    }
                    footer()
                        .frame(maxWidth: .infinity)
                }
                .font(theme.bodyFont)
                .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 80)
                // Behind the content: a click in the margins or between blocks clears
                // any active text selection, so clicking outside the text deselects.
                .background(SelectionClearingBackground())
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    /// One run of text blocks. The run also reports where each block starts in
    /// it, so the reader can name the block at the top of the window and scroll
    /// back to it later.
    private func textRun(blocks: [Markup], firstBlock: Int) -> some View {
        let run = MarkdownTextRun.build(blocks, theme: theme)
        return SelectableTextView(
            attributed: run.attributed,
            blockOffsets: run.blockOffsets,
            firstBlock: firstBlock,
            highlights: highlights,
            onHighlight: onHighlight
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
