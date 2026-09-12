// SPDX-License-Identifier: GPL-3.0-or-later

import Markdown
import SwiftUI

// Both SwiftUI and Markdown export `Text` and `Image`. These file-scope aliases
// make the bare names resolve to SwiftUI; Markdown's nodes are used qualified
// (`Markdown.Text`, `Markdown.Image`).
private typealias Text = SwiftUI.Text
private typealias Image = SwiftUI.Image

/// Renders a single block-level Markdown node as native SwiftUI. Container
/// blocks (lists, quotes, list items) recurse back through this view.
struct MarkdownBlockView: View {
    let block: Markup
    let theme: MarkdownTheme
    let assetBaseURL: URL?
    /// Verbatim highlight strings and the highlight callback, threaded to the
    /// `SelectableTextView`s that back lists, block quotes, and image captions so
    /// those blocks get the same highlight tint and Highlight/Look Up menu as
    /// body-text runs.
    var highlights: [String] = []
    var onHighlight: (String) -> Void = { _ in }

    var body: some View {
        switch block {
        case let heading as Heading:
            HeadingView(heading: heading, theme: theme)

        case let paragraph as Paragraph:
            ParagraphView(paragraph: paragraph, theme: theme, assetBaseURL: assetBaseURL,
                          highlights: highlights, onHighlight: onHighlight)

        case let quote as BlockQuote:
            // Reached only for image-bearing quotes — image-free quotes fold into
            // a shared text run (see `ArticleDocument.isFoldable`). Rendered as
            // SwiftUI so the embedded image lays out as a figure; the highlight
            // plumbing reaches any figure captions inside.
            HStack(spacing: theme.quoteBarGap) {
                RoundedRectangle(cornerRadius: theme.quoteBarWidth / 2)
                    .fill(.secondary.opacity(0.4))
                    .frame(width: theme.quoteBarWidth)
                VStack(alignment: .leading, spacing: theme.quoteInnerSpacing) {
                    ForEach(childArray(quote)) { item in
                        MarkdownBlockView(block: item.markup, theme: theme, assetBaseURL: assetBaseURL,
                                          highlights: highlights, onHighlight: onHighlight)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let list as UnorderedList:
            // Reached only for image-bearing lists — image-free lists fold into a
            // shared text run (see `ArticleDocument.isFoldable`). SwiftUI keeps the
            // embedded figures.
            ListView(items: childArray(list), ordered: false, startIndex: 1,
                     depth: 0, theme: theme, assetBaseURL: assetBaseURL)

        case let list as OrderedList:
            ListView(items: childArray(list), ordered: true, startIndex: Int(list.startIndex),
                     depth: 0, theme: theme, assetBaseURL: assetBaseURL)

        case let item as ListItem:
            // Reached only if a ListItem is rendered outside a ListView; lists
            // normally route item content through `ListItemContent`.
            ListItemContent(item: item, depth: 0, theme: theme, assetBaseURL: assetBaseURL)

        case let code as CodeBlock:
            CodeBlockView(code: code.code, language: code.language, theme: theme)

        case is ThematicBreak:
            Divider().padding(.vertical, theme.ruleSpacing)

        case let table as Markdown.Table:
            MarkdownTableView(table: table, theme: theme)

        case let html as HTMLBlock:
            // Render visible text only; never raw tags.
            Text(html.rawHTML.strippingTags)
                .font(theme.bodyFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

        default:
            // Unknown container: recurse into children so nothing is dropped.
            VStack(alignment: .leading, spacing: theme.blockSpacing * 0.6) {
                ForEach(childArray(block)) { child in
                    MarkdownBlockView(block: child.markup, theme: theme, assetBaseURL: assetBaseURL,
                                      highlights: highlights, onHighlight: onHighlight)
                }
            }
        }
    }
}

// ── Heading ─────────────────────────────────────────────────────────────────

/// A heading rendered with its own size/weight (injected via `FontContext`, so
/// the heading font is not overridden by the per-run body font), extra space
/// above to mark a section break, and level-6 styled as a muted uppercase
/// eyebrow.
private struct HeadingView: View {
    let heading: Heading
    let theme: MarkdownTheme

    var body: some View {
        content
            .padding(.top, theme.headingSpaceAbove(heading.level))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        let level = heading.level
        if theme.headingIsEyebrow(level) {
            Text(InlineRenderer.plainText(heading).uppercased())
                .font(theme.headingFont(level))
                .tracking(theme.headingTracking(level))
                .foregroundStyle(.secondary)
        } else {
            Text(InlineRenderer.attributed(heading, theme: theme,
                                           context: .heading(level, theme)))
                .tracking(theme.headingTracking(level))
        }
    }
}

// ── Lists ───────────────────────────────────────────────────────────────────

/// An ordered or unordered list. `depth` drives the bullet glyph and lets
/// nested lists indent consistently. Item content is rendered by
/// `ListItemContent`, which recurses into nested lists with `depth + 1`.
private struct ListView: View {
    let items: [IdentifiedMarkup]
    let ordered: Bool
    let startIndex: Int
    var depth: Int = 0
    let theme: MarkdownTheme
    let assetBaseURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: theme.listMarkerGap) {
                    marker(for: index, item: item.markup)
                        .font(theme.bodyFont)
                        .foregroundStyle(.secondary)
                        .frame(width: theme.listMarkerWidth(ordered: ordered), alignment: .trailing)
                    ListItemContent(item: item.markup, depth: depth,
                                    theme: theme, assetBaseURL: assetBaseURL)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for index: Int, item: Markup) -> some View {
        if let listItem = item as? ListItem, let checkbox = listItem.checkbox {
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checkbox == .checked ? Color.accentColor : Color.secondary)
        } else if ordered {
            Text("\(startIndex + index).")
                .monospacedDigit()
        } else {
            Text(theme.bullet(depth: depth))
        }
    }
}

/// The content of one list item: its paragraphs/blocks, plus any nested lists
/// rendered one level deeper so the bullet style and indentation step down.
private struct ListItemContent: View {
    let item: Markup
    let depth: Int
    let theme: MarkdownTheme
    let assetBaseURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.blockSpacing * 0.5) {
            ForEach(childArray(item)) { child in
                switch child.markup {
                case let list as UnorderedList:
                    ListView(items: childArray(list), ordered: false, startIndex: 1,
                             depth: depth + 1, theme: theme, assetBaseURL: assetBaseURL)
                case let list as OrderedList:
                    ListView(items: childArray(list), ordered: true,
                             startIndex: Int(list.startIndex), depth: depth + 1,
                             theme: theme, assetBaseURL: assetBaseURL)
                default:
                    MarkdownBlockView(block: child.markup, theme: theme, assetBaseURL: assetBaseURL)
                }
            }
        }
    }
}

// ── Code block ──────────────────────────────────────────────────────────────

/// A fenced/indented code block. When a language is declared it's shown as a
/// small label above the scrollable, monospaced code surface.
private struct CodeBlockView: View {
    let code: String
    let language: String?
    let theme: MarkdownTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.lowercased())
                    .font(theme.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, theme.codePadding)
                    .padding(.top, theme.codePadding * 0.6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.hasSuffix("\n") ? String(code.dropLast()) : code)
                    .font(theme.codeFont)
                    .textSelection(.enabled)
                    .padding(theme.codePadding)
            }
        }
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: theme.codeCornerRadius))
    }
}

// ── Table ───────────────────────────────────────────────────────────────────

private struct MarkdownTableView: View {
    let table: Markdown.Table
    let theme: MarkdownTheme

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                // Cells/rows carry a unique source `range`; key on it so identity
                // is content-derived rather than the column/row position.
                ForEach(Array(table.head.cells.enumerated()), id: \.element.range) { index, cell in
                    Text(InlineRenderer.attributed(cell, theme: theme,
                                                   context: .emphasized(theme, weight: .semibold)))
                        .textSelection(.enabled)
                        .gridColumnAlignment(alignment(index))
                }
            }
            Divider()
            ForEach(Array(table.body.rows.enumerated()), id: \.element.range) { _, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.element.range) { _, cell in
                        Text(InlineRenderer.attributed(cell, theme: theme))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Map a column's Markdown alignment onto a SwiftUI grid alignment.
    private func alignment(_ index: Int) -> HorizontalAlignment {
        guard index < table.columnAlignments.count else { return .leading }
        switch table.columnAlignments[index] {
        case .some(.center): return .center
        case .some(.right): return .trailing
        default: return .leading
        }
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

private func childArray(_ markup: Markup) -> [IdentifiedMarkup] {
    Array(markup.children).enumerated().map {
        IdentifiedMarkup(id: IdentifiedMarkup.stableID(for: $0.element, fallbackIndex: $0.offset),
                         markup: $0.element)
    }
}

private extension String {
    /// Crude tag stripper for raw HTML blocks.
    var strippingTags: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
