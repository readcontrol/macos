// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Markdown
import SwiftUI

/// Coalesces a run of contiguous *text* blocks — headings, text-only
/// paragraphs, lists, and block quotes — into a single `NSAttributedString` so
/// an `NSTextView` can offer continuous selection across them. The theme's
/// reading rhythm (line spacing, inter-block gaps, heading space-above) and its
/// structural layout (list marker columns via tab stops, quote indentation) are
/// re-expressed here as `NSParagraphStyle` attributes, since a single text view
/// has no per-block SwiftUI modifiers. Quote bars are drawn by
/// `ReaderLayoutManager` from the `.quoteBar` attribute this builder attaches.
enum MarkdownTextRun {
    /// One laid-out paragraph: its text (without a trailing newline) and the
    /// paragraph style to apply over it. `spacingBefore` is the gap from the
    /// previous paragraph; the caller fixes the run's very first paragraph.
    private struct Para {
        var content: NSAttributedString
        var style: NSMutableParagraphStyle
        var spacingBefore: CGFloat
    }

    /// Context threaded down the block tree: the current left indent (points),
    /// list nesting depth (drives bullet glyphs), text color, and the x-offsets
    /// of any enclosing quote bars.
    private struct Ctx {
        var indent: CGFloat = 0
        var listDepth: Int = 0
        var color: NSColor = .labelColor
        var bars: [CGFloat] = []
    }

    /// One built run: the text to show, plus where each top-level block starts
    /// in it. The reader needs the offsets to name the block at the top of the
    /// window, and to scroll back to a block it recorded before.
    struct Built {
        var attributed: NSAttributedString
        /// Character offset in `attributed` of each block, in the order given.
        /// A block that emits nothing keeps the offset of the next one.
        var blockOffsets: [Int]
    }

    static func attributed(_ blocks: [Markup], theme: MarkdownTheme) -> NSAttributedString {
        build(blocks, theme: theme).attributed
    }

    /// Build the run and report where each top-level block starts in it.
    static func build(_ blocks: [Markup], theme: MarkdownTheme) -> Built {
        var paras: [Para] = []
        // The index in `paras` where each block's first paragraph begins. A block
        // that emits no paragraph shares the index of the block after it.
        var paraStarts: [Int] = []
        for (index, block) in blocks.enumerated() {
            paraStarts.append(paras.count)
            var blockParas = emit(block, theme: theme, ctx: Ctx())
            guard !blockParas.isEmpty else { continue }
            // Leading gap for this top-level block: the inter-block rhythm, plus
            // a heading's asymmetric space-above. The run's first paragraph gets
            // no leading gap (the enclosing LazyVStack provides it).
            let lead = index == 0 ? 0 : theme.blockSpacing
            let headingExtra = (block as? Heading).map { theme.headingSpaceAbove($0.level) } ?? 0
            blockParas[0].spacingBefore = lead + headingExtra
            paras.append(contentsOf: blockParas)
        }

        let out = NSMutableAttributedString()
        // Character offset in `out` where each paragraph starts.
        var paraOffsets: [Int] = []
        for (index, para) in paras.enumerated() {
            let start = out.length
            paraOffsets.append(start)
            out.append(para.content)
            // Terminate every paragraph but the last; the newline belongs to the
            // current paragraph's range so its style covers the terminator.
            if index < paras.count - 1 {
                out.append(NSAttributedString(string: "\n"))
            }
            para.style.paragraphSpacingBefore = para.spacingBefore
            out.addAttribute(.paragraphStyle, value: para.style,
                             range: NSRange(location: start, length: out.length - start))
        }

        let blockOffsets = paraStarts.map { start in
            start < paraOffsets.count ? paraOffsets[start] : out.length
        }
        return Built(attributed: out, blockOffsets: blockOffsets)
    }

    // ── Block emitters ───────────────────────────────────────────────────────

    private static func emit(_ block: Markup, theme: MarkdownTheme, ctx: Ctx) -> [Para] {
        switch block {
        case let heading as Heading:
            return [headingParagraph(heading, theme: theme, ctx: ctx)]
        case let paragraph as Paragraph:
            return [textParagraph(paragraph, theme: theme, ctx: ctx)]
        case let list as UnorderedList:
            return emitList(Array(list.listItems), ordered: false, start: 1, theme: theme, ctx: ctx)
        case let list as OrderedList:
            return emitList(Array(list.listItems), ordered: true, start: Int(list.startIndex),
                            theme: theme, ctx: ctx)
        case let quote as BlockQuote:
            var qctx = ctx
            qctx.bars = ctx.bars + [ctx.indent]
            qctx.indent = ctx.indent + theme.quoteBarWidth + theme.quoteBarGap
            qctx.color = .secondaryLabelColor
            return emitSequence(quote.blockChildren.map { $0 as Markup }, theme: theme,
                                ctx: qctx, innerGap: theme.quoteInnerSpacing)
        default:
            // Foldability is checked before we get here, so this is only reached
            // for unexpected containers; recurse so nothing is dropped.
            return emitSequence(Array(block.children), theme: theme, ctx: ctx,
                                innerGap: theme.blockSpacing)
        }
    }

    /// Emit a sequence of sibling blocks, setting the gap before each (the first
    /// keeps 0 so the parent decides its leading gap).
    private static func emitSequence(_ blocks: [Markup], theme: MarkdownTheme,
                                     ctx: Ctx, innerGap: CGFloat) -> [Para]
    {
        var result: [Para] = []
        for (index, block) in blocks.enumerated() {
            var paras = emit(block, theme: theme, ctx: ctx)
            if index > 0, !paras.isEmpty {
                paras[0].spacingBefore = innerGap
            }
            result.append(contentsOf: paras)
        }
        return result
    }

    private static func emitList(_ items: [ListItem], ordered: Bool, start: Int,
                                 theme: MarkdownTheme, ctx: Ctx) -> [Para]
    {
        let markerWidth = theme.listMarkerWidth(ordered: ordered)
        let bodyIndent = ctx.indent + markerWidth + theme.listMarkerGap

        var childCtx = ctx
        childCtx.indent = bodyIndent
        childCtx.listDepth = ctx.listDepth + 1

        var result: [Para] = []
        for (index, item) in items.enumerated() {
            var itemParas = emitSequence(item.blockChildren.map { $0 as Markup }, theme: theme,
                                         ctx: childCtx, innerGap: theme.blockSpacing * 0.5)
            if itemParas.isEmpty {
                itemParas = [textPlaceholder(ctx: childCtx, theme: theme)]
            }

            // Prepend the marker to the item's first paragraph, then give that
            // paragraph a hanging-indent style.
            let marker = markerString(ordered: ordered, number: start + index,
                                      item: item, depth: ctx.listDepth, theme: theme)
            let line = NSMutableAttributedString(string: "\t")
            line.append(marker)
            line.append(NSAttributedString(string: "\t"))
            line.append(itemParas[0].content)
            applyBars(line, ctx.bars)
            itemParas[0].content = line

            applyHangingIndent(itemParas[0].style, ctx: ctx, markerWidth: markerWidth, bodyIndent: bodyIndent)

            itemParas[0].spacingBefore = index == 0 ? 0 : theme.listItemSpacing
            result.append(contentsOf: itemParas)
        }
        return result
    }

    /// Give a list item's first paragraph a hanging indent: a right tab
    /// right-aligns the marker in its column, a left tab starts the text at
    /// `bodyIndent`, and `headIndent` keeps wrapped lines under the text.
    private static func applyHangingIndent(_ style: NSMutableParagraphStyle, ctx: Ctx,
                                           markerWidth: CGFloat, bodyIndent: CGFloat)
    {
        style.firstLineHeadIndent = ctx.indent
        style.headIndent = bodyIndent
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: ctx.indent + markerWidth, options: [:]),
            NSTextTab(textAlignment: .left, location: bodyIndent, options: [:])
        ]
        style.defaultTabInterval = bodyIndent
    }

    // ── Leaf paragraphs ────────────────────────────────────────────────────────

    private static func textParagraph(_ paragraph: Markup, theme: MarkdownTheme, ctx: Ctx) -> Para {
        let content = NSMutableAttributedString(attributedString:
            AppKitInline.attributed(paragraph, size: theme.bodySize, weight: .regular,
                                    design: theme.design, color: ctx.color))
        applyBars(content, ctx.bars)
        let style = baseStyle(indent: ctx.indent)
        style.lineSpacing = theme.lineSpacing
        return Para(content: content, style: style, spacingBefore: 0)
    }

    private static func headingParagraph(_ heading: Heading, theme: MarkdownTheme, ctx: Ctx) -> Para {
        let level = heading.level
        let content: NSMutableAttributedString
        if theme.headingIsEyebrow(level) {
            let font = AppKitInline.makeFont(size: theme.headingSize(level),
                                             weight: theme.headingWeight(level),
                                             design: theme.design, bold: false, italic: false)
            content = NSMutableAttributedString(
                string: InlineRenderer.plainText(heading).uppercased(),
                attributes: [.font: font,
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .kern: theme.headingTracking(level)]
            )
        } else {
            content = NSMutableAttributedString(attributedString:
                AppKitInline.attributed(heading, size: theme.headingSize(level),
                                        weight: theme.headingWeight(level),
                                        design: theme.design, color: ctx.color))
            let tracking = theme.headingTracking(level)
            if tracking != 0 {
                content.addAttribute(.kern, value: tracking,
                                     range: NSRange(location: 0, length: content.length))
            }
        }
        applyBars(content, ctx.bars)
        let style = baseStyle(indent: ctx.indent)
        return Para(content: content, style: style, spacingBefore: 0)
    }

    /// An empty list item still needs a line so its marker renders.
    private static func textPlaceholder(ctx: Ctx, theme: MarkdownTheme) -> Para {
        let style = baseStyle(indent: ctx.indent)
        style.lineSpacing = theme.lineSpacing
        return Para(content: NSAttributedString(string: ""), style: style, spacingBefore: 0)
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    private static func baseStyle(indent: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    private static func markerString(ordered: Bool, number: Int, item: ListItem,
                                     depth: Int, theme: MarkdownTheme) -> NSAttributedString
    {
        if let checkbox = item.checkbox {
            let checked = checkbox == .checked
            let font = AppKitInline.makeFont(size: theme.bodySize, weight: .regular,
                                             design: theme.design, bold: false, italic: false)
            return NSAttributedString(string: checked ? "☑" : "☐", attributes: [
                .font: font,
                .foregroundColor: checked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            ])
        }
        let glyph = ordered ? "\(number)." : theme.bullet(depth: depth)
        let font = ordered
            ? NSFont.monospacedDigitSystemFont(ofSize: theme.bodySize, weight: .regular)
            : AppKitInline.makeFont(size: theme.bodySize, weight: .regular,
                                    design: theme.design, bold: false, italic: false)
        return NSAttributedString(string: glyph, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    /// Tag a paragraph with the x-offsets of its enclosing quote bars so
    /// `ReaderLayoutManager` can draw them in the margin.
    private static func applyBars(_ string: NSMutableAttributedString, _ bars: [CGFloat]) {
        guard !bars.isEmpty, string.length > 0 else { return }
        string.addAttribute(.quoteBar, value: bars,
                            range: NSRange(location: 0, length: string.length))
    }
}
