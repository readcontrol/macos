// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An isolated, on-disk library for one test: `<tmp>/<uuid>/library/` with a
/// sibling `<tmp>/<uuid>/index.db`. Each reading is its own folder,
/// `articles/<prefix>/<id>/` holding `article.md`, an `assets/` sub-folder, and
/// `highlights.md` — the layout the real scanner indexes. Fixtures written here
/// are indexed by the real app — before launch (the boot rebuild picks them up)
/// or after (exercising the FSEvents watcher). Destroyed in teardown.
final class TestLibrary {
    /// `<tmp>/<uuid>` — the per-test root holding both the library and the DB.
    let root: URL
    /// The library folder the app is pointed at (`root/library`).
    let libraryURL: URL
    /// The index DB path (`root/index.db`), kept outside the library per the contract.
    let dbURL: URL

    /// A throwaway `UserDefaults` suite name the app is pointed at for this test, so
    /// preference changes never touch the real `app.readcontrol.app` domain. Destroyed
    /// in `destroy()`.
    let defaultsSuiteName: String

    var articlesDir: URL {
        libraryURL.appendingPathComponent("articles", isDirectory: true)
    }

    /// A reading's own folder, `articles/<prefix>/<id>/`, where `<prefix>` is the
    /// first two characters of the id — the fan-out layout the scanner walks.
    func readingDir(id: String) -> URL {
        articlesDir
            .appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    init() throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadControlUITests", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        libraryURL = root.appendingPathComponent("library", isDirectory: true)
        dbURL = root.appendingPathComponent("index.db")
        defaultsSuiteName = "app.readcontrol.app.uitest.\(id)"
        try FileManager.default.createDirectory(at: articlesDir, withIntermediateDirectories: true)
    }

    // ── Articles ────────────────────────────────────────────────────────────

    func write(_ article: ArticleFixture) throws {
        try FileManager.default.createDirectory(
            at: readingDir(id: article.id), withIntermediateDirectories: true
        )
        try article.rendered().write(to: articleFileURL(id: article.id), atomically: true, encoding: .utf8)
    }

    func write(_ articles: [ArticleFixture]) throws {
        for article in articles {
            try write(article)
        }
    }

    /// Writes arbitrary file contents for `id` — for external-edit and malformed-file tests.
    func writeRaw(id: String, contents: String) throws {
        try FileManager.default.createDirectory(
            at: readingDir(id: id), withIntermediateDirectories: true
        )
        try contents.write(to: articleFileURL(id: id), atomically: true, encoding: .utf8)
    }

    /// Removes the reading's `article.md`, leaving any assets/highlights — the
    /// scanner then treats the folder (now without an article) as a removal.
    func deleteArticle(id: String) throws {
        try FileManager.default.removeItem(at: articleFileURL(id: id))
    }

    func articleExists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: articleFileURL(id: id).path)
    }

    /// The raw file contents for `id`, or nil if it doesn't exist.
    func articleContents(id: String) -> String? {
        try? String(contentsOf: articleFileURL(id: id), encoding: .utf8)
    }

    /// The parsed frontmatter for `id`, or nil if the file is missing/unfenced.
    func frontmatter(id: String) -> Frontmatter? {
        articleContents(id: id).flatMap(Frontmatter.init(contents:))
    }

    // ── Assets & highlights ───────────────────────────────────────────────

    func writeAsset(articleId: String, fileName: String, data: Data) throws {
        let dir = readingDir(id: articleId).appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(fileName))
    }

    func writeHighlights(articleId: String, _ highlights: [TestHighlight]) throws {
        try FileManager.default.createDirectory(
            at: readingDir(id: articleId), withIntermediateDirectories: true
        )
        try HighlightsFile.render(highlights)
            .write(to: highlightsFileURL(id: articleId), atomically: true, encoding: .utf8)
    }

    func highlightsExist(articleId: String) -> Bool {
        FileManager.default.fileExists(atPath: highlightsFileURL(id: articleId).path)
    }

    /// Raw contents of a reading's highlights file, or nil if it doesn't exist.
    func highlightsContents(articleId: String) -> String? {
        try? String(contentsOf: highlightsFileURL(id: articleId), encoding: .utf8)
    }

    // ── Reading position ──────────────────────────────────────────────────

    /// Whether the reading has a position file. The core deletes it when the
    /// user goes back to the start, or when the reading is marked read.
    func positionExists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: positionFileURL(id: id).path)
    }

    /// The parsed reading position for `id`, or nil when the file is absent or
    /// still half-written.
    func position(id: String) -> PositionFile? {
        (try? String(contentsOf: positionFileURL(id: id), encoding: .utf8))
            .flatMap(PositionFile.init(contents:))
    }

    // ── URL accessors ─────────────────────────────────────────────────────

    func articleFileURL(id: String) -> URL {
        readingDir(id: id).appendingPathComponent("article.md")
    }

    func highlightsFileURL(id: String) -> URL {
        readingDir(id: id).appendingPathComponent("highlights.md")
    }

    func positionFileURL(id: String) -> URL {
        readingDir(id: id).appendingPathComponent("position.md")
    }

    // ── Teardown ────────────────────────────────────────────────────────────

    func destroy() {
        // Drop the isolated preferences suite the app wrote to (values + backing
        // plist), then the temp library tree.
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
