// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Base class every UI test sits on. It gives each test an isolated temp library
/// (so tests never see each other's data) *and* an isolated `UserDefaults` suite
/// (so preference changes never touch the real `app.readcontrol.app` domain),
/// launches the app against both, and — on teardown — terminates the app and
/// destroys the temp library and its defaults suite. The dev's real library
/// bookmark and preferences are never touched.
class UITestCase: XCTestCase {
    /// The running app under test, set by a `launch*` call.
    private(set) var app: XCUIApplication!

    /// The isolated temp library the app was launched against; destroyed on teardown.
    private(set) var library: TestLibrary!

    // ── Lifecycle ───────────────────────────────────────────────────────────

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        library?.destroy() // also drops the isolated defaults suite
        library = nil
    }

    // ── Launch ────────────────────────────────────────────────────────────

    /// Launch straight into the main view against a fresh temp library seeded
    /// with `articles` (empty by default). The boot rebuild indexes them before
    /// the window appears.
    @discardableResult
    func launchApp(
        articles: [ArticleFixture] = [],
        configure: (inout LaunchOptions) -> Void = { _ in }
    ) throws -> XCUIApplication {
        let library = try TestLibrary()
        try library.write(articles)
        self.library = library

        var options = LaunchOptions(libraryPath: library.libraryURL.path, dbPath: library.dbURL.path)
        options.defaultsSuite = library.defaultsSuiteName
        // The app now opens on Unread by default; pin All here so the many tests
        // written against that original landing view keep starting there without an
        // explicit `sidebar.select(.all)`. A test exercising the real default just
        // drops this pin (`options.pinnedDefaults.removeValue(forKey: "activeView")`).
        options.pinnedDefaults["activeView"] = SmartView.all.rawValue
        configure(&options)
        app = AppLauncher.launch(options)
        XCTAssertTrue(
            app.byId(A11y.Sidebar.viewRow("all")).waitForExistence(timeout: 20),
            "Main view (sidebar) did not appear after launch."
        )
        return app
    }

    /// Launch into onboarding (no library configured). `onboardingPickPath` is
    /// pointed at the temp library's folder, so clicking "Choose Library…"
    /// scaffolds *that* — keeping the flow testable without a system open panel.
    @discardableResult
    func launchOnboarding(configure: (inout LaunchOptions) -> Void = { _ in }) throws -> XCUIApplication {
        let library = try TestLibrary()
        self.library = library

        var options = LaunchOptions(
            dbPath: library.dbURL.path,
            onboardingPickPath: library.libraryURL.path
        )
        options.defaultsSuite = library.defaultsSuiteName
        configure(&options)
        app = AppLauncher.launch(options)
        XCTAssertTrue(
            app.byId(A11y.Onboarding.chooseLibrary).waitForExistence(timeout: 20),
            "Onboarding did not appear after launch."
        )
        return app
    }

    /// Terminates the running app and relaunches it against the **same** temp
    /// library, DB, and defaults suite, so a test can assert that persisted
    /// preferences survive a restart. Applies no defaults pins by default: the app
    /// must read back what it wrote (a pin would shadow the persisted value through
    /// the NSArgumentDomain).
    @discardableResult
    func relaunchApp(configure: (inout LaunchOptions) -> Void = { _ in }) -> XCUIApplication {
        app?.terminate()
        var options = LaunchOptions(libraryPath: library.libraryURL.path, dbPath: library.dbURL.path)
        options.defaultsSuite = library.defaultsSuiteName
        configure(&options)
        app = AppLauncher.launch(options)
        XCTAssertTrue(
            app.byId(A11y.Sidebar.viewRow("all")).waitForExistence(timeout: 20),
            "Main view (sidebar) did not appear after relaunch."
        )
        return app
    }

    // ── Page objects ────────────────────────────────────────────────────────
    // Convenience accessors so a test reads as `sidebar.select(.unread)` etc.
    // All wrap the running `app`; use them only after a `launch*` call.

    var onboarding: OnboardingPage {
        OnboardingPage(app: app)
    }

    var sidebar: SidebarPage {
        SidebarPage(app: app)
    }

    var list: ReadingListPage {
        ReadingListPage(app: app)
    }

    var reader: ReaderPage {
        ReaderPage(app: app)
    }

    var tagPicker: TagPickerPage {
        TagPickerPage(app: app)
    }

    var highlightsInspector: HighlightsPage {
        HighlightsPage(app: app)
    }

    var shortcutsSheet: ShortcutsSheetPage {
        ShortcutsSheetPage(app: app)
    }

    var settings: SettingsPage {
        SettingsPage(app: app)
    }

    var keyboard: Keyboard {
        Keyboard(app: app)
    }

    // ── On-disk assertions ────────────────────────────────────────────────

    /// Polls the on-disk article file for `id` until `predicate(frontmatter)`
    /// holds or `timeout` elapses — the "file is the source of truth" check after
    /// a mutation. Returns whether the predicate was satisfied in time.
    @discardableResult
    func waitForFrontmatter(
        id: String,
        timeout: TimeInterval = 8,
        _ predicate: (Frontmatter) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let frontmatter = library?.frontmatter(id: id), predicate(frontmatter) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    /// Polls the on-disk `position.md` for `id` until `predicate(position)` holds
    /// or `timeout` elapses — the file-is-the-truth check after the reader
    /// recorded where the user stopped. The reader writes one time for each stop
    /// of the scroll, thus the default timeout leaves room for the settle delay.
    @discardableResult
    func waitForPosition(
        id: String,
        timeout: TimeInterval = 10,
        _ predicate: (PositionFile) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let position = library?.position(id: id), predicate(position) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    /// Generic poll: waits until `condition()` holds or `timeout` elapses. For
    /// on-disk / cross-cutting assertions that aren't a single element or default.
    @discardableResult
    func wait(timeout: TimeInterval = 8, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }
}
