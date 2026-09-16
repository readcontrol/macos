// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

// ── Library lifecycle ────────────────────────────────────────────────────────
// Choosing/restoring the library folder, booting the core against it, and
// keeping the index in sync with on-disk changes (FSEvents).

extension AppState {
    // ── Onboarding ────────────────────────────────────────────────────────

    func chooseLibrary() {
        // UI-testing: pick the scripted folder directly — NSOpenPanel is a
        // system dialog XCUITest can't reliably drive.
        if let path = TestHooks.onboardingPickPath {
            Task { await pickLibrary(url: URL(fileURLWithPath: path)) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Library Folder"
        panel.message = "Select or create a folder to store your articles."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await pickLibrary(url: url) }
    }

    private func pickLibrary(url: URL) async {
        do {
            try LibrarySetup.scaffold(at: url)
            WelcomeArticle.seedIfEmpty(in: url)
            // Keep scaffolding + welcome seed so onboarding stays testable, but
            // in UI-testing mode skip the security-scoped bookmark handoff so
            // the dev's persisted library bookmark is never overwritten.
            if !TestHooks.isUITesting {
                try LibraryBookmark.save(url: url)
                stopAccessing()
                accessedURL = LibraryBookmark.resolve()
            }
            // Raise the extension-install step *before* boot flips `libraryURL`,
            // so the main view never flashes in the gap while boot finishes
            // indexing (boot sets `libraryURL`, then `await`s a refresh — a window
            // in which the reading list would otherwise render). It's a
            // first-run-only prompt: skip it once the user has dismissed it, so
            // re-picking the library from Settings doesn't resurface it. Restoring
            // a saved library on launch goes straight through `boot`, never here.
            if !hasCompletedExtensionSetup {
                showExtensionSetup = true
            }
            await boot(url: url)
            // Boot swallows its errors; if it couldn't open the library,
            // `libraryURL` stays nil — drop the flag so a retry starts clean.
            if libraryURL == nil {
                showExtensionSetup = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // ── Boot ──────────────────────────────────────────────────────────────

    func boot(url: URL) async {
        isLoading = true
        error = nil
        do {
            let bridge = try CoreBridge(libraryPath: url.path, dbPath: Self.dbPath())
            try await bridge.rebuild()
            core = bridge
            // Before `libraryURL` shows the reading list, so the list never
            // selects its first row in place of the last reading.
            await resumeLastReading(core: bridge)
            libraryURL = url
            // Host-machine side effects (the ~/.config/readcontrol/library file
            // and the browser native-messaging manifest) are neutralized under
            // UI testing so runs don't touch the real machine's config.
            if !TestHooks.isUITesting {
                writeLibraryPathConfig(url.path)
                NativeHostInstaller.install()
            }
            startWatcher(libraryPath: url.path)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        isRestoringLibrary = false
    }

    /// Open the reading the user had open: the current selection when the user
    /// picks another library, or else the reading open when the app quit. The
    /// list can not show that reading (another filter, a later page), thus ask
    /// the index. When the index does not have it (deleted, or from another
    /// library), clear the selection, and the list selects its first row.
    private func resumeLastReading(core: any CoreBridging) async {
        guard let id = selectedId ?? lastReadingId else { return }
        let exists = await (try? core.getReadingRow(id: id)) != nil
        selectedId = exists ? id : nil
    }

    /// Write the library path to ~/.config/readcontrol/library so the native
    /// messaging host can find it without needing a security-scoped bookmark.
    private func writeLibraryPathConfig(_ path: String) {
        let configDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/readcontrol", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true
        )
        try? (path + "\n").write(
            to: configDir.appendingPathComponent("library"),
            atomically: true, encoding: .utf8
        )
    }

    // ── Incremental sync (FSEvents) ───────────────────────────────────────

    func sync() async {
        guard let core else { return }
        do {
            let changed = try await core.sync()
            if changed > 0 {
                await refresh()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startWatcher(libraryPath: String) {
        // Tear down the previous watcher before replacing it. Reassigning alone
        // would leak it — the FSEvents stream keeps it alive, still watching the
        // old folder and firing sync() against the new library. invalidate()
        // runs while we still hold the strong reference, so the release it
        // triggers can't deallocate the watcher mid-teardown.
        watcher?.invalidate()
        watcher = FolderWatcher(libraryPath: libraryPath) { [weak self] in
            Task { @MainActor [weak self] in await self?.sync() }
        }
    }

    // ── Security-scoped resource ──────────────────────────────────────────

    private func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    static func dbPath() -> String {
        // UI-testing: use the pinned temp DB so the real per-device index is
        // never opened or mutated.
        if let path = TestHooks.dbPath {
            return path
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("index.db").path
    }
}
