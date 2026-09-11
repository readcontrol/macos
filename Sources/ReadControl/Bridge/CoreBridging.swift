// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The async surface `AppState` uses to reach the Rust core. `AppState` depends
/// on this protocol rather than the concrete `CoreBridge` actor, so a test double
/// can stand in for the real core (no Rust, no filesystem) — see ADR 0001.
///
/// The methods are `async throws` here; `CoreBridge`'s actor-isolated synchronous
/// methods witness them (a call from outside an actor is implicitly async).
/// Boundary DTOs (`Ffi*`) appear in the signatures because this is the bridge.
protocol CoreBridging: Sendable {
    func rebuild() async throws
    @discardableResult func sync() async throws -> UInt32

    func listReadings(_ query: ReadingQuery) async throws -> [FfiReadingRow]
    func sidebarCounts(
        view: SidebarItem, tag: String?, rating: UInt8?, query: String?
    ) async throws -> FfiSidebarCounts
    func getReadingRow(id: String) async throws -> FfiReadingRow?
    func getBody(id: String) async throws -> String?

    func addTag(id: String, tag: String) async throws
    func removeTag(id: String, tag: String) async throws

    func setRead(id: String, read: Bool) async throws
    func setArchived(id: String, archived: Bool) async throws
    func setFavorite(id: String, favorite: Bool) async throws
    func setRating(id: String, rating: UInt8) async throws

    func deleteReading(id: String) async throws

    func listHighlights(readingId: String) async throws -> [FfiHighlight]
    @discardableResult func addHighlight(readingId: String, text: String) async throws -> FfiHighlight
    @discardableResult func toggleHighlight(readingId: String, text: String) async throws -> Bool
    func deleteHighlight(readingId: String, highlightId: String) async throws

    func getPosition(readingId: String) async throws -> FfiPosition?
    @discardableResult func setPosition(readingId: String, block: UInt32, quote: String,
                                        percent: Float) async throws -> FfiPosition?
    func clearPosition(readingId: String) async throws
}

/// CoreBridge already implements every requirement; this just records the
/// conformance.
extension CoreBridge: CoreBridging {}
