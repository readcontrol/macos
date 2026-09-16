// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A minimal reader for a reading's `position.md`, so a journey can assert the
/// on-disk truth of where the user stopped — the project's "files are the source
/// of truth" principle, the same way `Frontmatter` covers the article file.
///
/// The format is one quote line and one field comment (see the "Reading
/// position" section of `docs/library-format.md`):
///
/// ```markdown
/// > The first line of the paragraph where the user stopped.
/// <!-- pos block=42 percent=0.63 at=2026-08-18T10:12:04.881Z -->
/// ```
struct PositionFile {
    /// 0-based index of the anchor block in the body.
    let block: Int
    /// The start of the anchor block, on one line.
    let quote: String
    /// The progress before the anchor block, from 0.0 to 1.0.
    let percent: Float
    /// The UTC time of the last change (the format calls this field `at`).
    let changedAt: String

    /// Parses the file, or returns nil while it holds no complete record — a
    /// read that lands mid-write, which a polling caller simply retries.
    init?(contents: String) {
        var quoteLines: [String] = []
        var fields: String?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            if let rest = line.hasPrefix("<!-- pos ") ? line.dropFirst("<!-- pos ".count) : nil {
                fields = String(rest)
                break
            }
            if line.hasPrefix("> ") {
                quoteLines.append(String(line.dropFirst(2)))
            }
        }
        // The comment must be closed: a file a sync tool cut short is not a record.
        guard let fields, let close = fields.range(of: "-->") else { return nil }
        let body = fields[..<close.lowerBound].trimmingCharacters(in: .whitespaces)

        var parsed: [String: String] = [:]
        for token in body.split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            if pair.count == 2 {
                parsed[String(pair[0])] = String(pair[1])
            }
        }
        guard let block = parsed["block"].flatMap(Int.init),
              let percent = parsed["percent"].flatMap(Float.init),
              let changedAt = parsed["at"], !changedAt.isEmpty
        else { return nil }

        self.block = block
        self.percent = percent
        self.changedAt = changedAt
        quote = quoteLines.joined(separator: " ")
    }
}
