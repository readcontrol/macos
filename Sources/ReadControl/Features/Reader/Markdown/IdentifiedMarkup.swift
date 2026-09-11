// SPDX-License-Identifier: GPL-3.0-or-later

import Markdown

/// Wraps a `Markup` child with a stable identity for `ForEach`.
struct IdentifiedMarkup: Identifiable {
    let id: String
    let markup: Markup

    /// A stable identity for a parsed node, taken from its span in the *source*
    /// text rather than its index in a rendered array. `Document(parsing:)`
    /// assigns every node a unique source range, so sibling nodes never share a
    /// start location; the index fallback (only reached for nodes without range
    /// info, e.g. programmatically built ones) stays unique within its
    /// collection. Position-based ids (`\.offset`) instead reset per-row state
    /// on any insert/reorder — harmless for immutable parsed content, but this
    /// keeps identity content-derived per the list-identity rule.
    static func stableID(for markup: Markup, fallbackIndex index: Int) -> String {
        if let start = markup.range?.lowerBound {
            return "\(start.line):\(start.column)"
        }
        return "#\(index)"
    }
}
