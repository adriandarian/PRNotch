import AppKit
import XCTest
@testable import PRNotch

final class FlyoutPresentationTests: XCTestCase {
    @MainActor
    func testEnteringRowCancelsPendingCollapseAndLeavingRestartsIt() async throws {
        let store = PullRequestStore()
        store.loadPreviewData()
        let entry = try XCTUnwrap(store.railEntries.first)
        store.surfaceHoverChanged(.rail, isInside: false)
        store.previewEntry(id: entry.id)

        try await Task.sleep(for: .milliseconds(520))
        XCTAssertTrue(store.isExpanded)
        XCTAssertTrue(store.isRailRevealed)

        store.endPreview(id: entry.id)
        try await Task.sleep(for: .milliseconds(520))
        XCTAssertFalse(store.isExpanded)
        XCTAssertFalse(store.isRailRevealed)
        store.stopSync()
    }

    @MainActor
    func testSpaceChangeResetsHoverAndAllowsFlyoutToReopen() async throws {
        _ = NSApplication.shared
        let store = PullRequestStore()
        store.loadPreviewData()
        let controller = PRNotchPanelController(store: store)
        let rail = try XCTUnwrap(NSApp.windows.first {
            $0.contentView is FirstMouseHostingView<NotchRailView>
        })
        let detail = try XCTUnwrap(NSApp.windows.first {
            $0.contentView is FirstMouseHostingView<PullRequestDetailView>
        })
        defer {
            controller.prepareForTermination()
            rail.close()
            detail.close()
        }
        controller.show()
        let entry = try XCTUnwrap(store.railEntries.first)
        store.surfaceHoverChanged(.rail, isInside: true)
        store.surfaceHoverChanged(.detail, isInside: true)
        store.activateEntry(id: entry.id)
        XCTAssertTrue(detail.isVisible)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        XCTAssertFalse(store.isExpanded)
        XCTAssertNil(store.hoveredEntryID)
        XCTAssertFalse(detail.isVisible)
        try await Task.sleep(for: .milliseconds(300))
        store.surfaceHoverChanged(.rail, isInside: true)
        store.previewEntry(id: entry.id)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(store.isExpanded)
        XCTAssertTrue(detail.isVisible)
        XCTAssertEqual(detail.alphaValue, 1, accuracy: 0.01)
        XCTAssertTrue(detail.isOnActiveSpace)
        XCTAssertTrue(rail.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(detail.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(rail.contentView?.trackingAreas.contains {
            $0.options.contains(.activeAlways) && $0.options.contains(.mouseMoved)
        } == true)
    }

    @MainActor
    func testReopeningDuringDismissalKeepsFlyoutVisible() async throws {
        _ = NSApplication.shared
        let store = PullRequestStore()
        store.loadPreviewData()
        let controller = PRNotchPanelController(store: store)
        let rail = try XCTUnwrap(NSApp.windows.first {
            $0.contentView is FirstMouseHostingView<NotchRailView>
        })
        let detail = try XCTUnwrap(NSApp.windows.first {
            $0.contentView is FirstMouseHostingView<PullRequestDetailView>
        })
        defer {
            controller.prepareForTermination()
            rail.close()
            detail.close()
        }
        controller.show()
        let entries = store.railEntries
        store.surfaceHoverChanged(.rail, isInside: true)
        store.activateEntry(id: entries[0].id)
        try await Task.sleep(for: .milliseconds(400))
        store.collapse()
        try await Task.sleep(for: .milliseconds(50))
        store.activateEntry(id: entries[1].id)
        try await Task.sleep(for: .milliseconds(450))

        XCTAssertTrue(detail.isVisible)
        XCTAssertEqual(detail.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(store.selectedEntryID, entries[1].id)
    }

    @MainActor
    func testLeavingPreviousRowDoesNotCancelNewRowsPreview() async throws {
        let store = PullRequestStore()
        store.loadPreviewData()
        let entries = store.railEntries
        store.previewEntry(id: entries[0].id)
        store.previewEntry(id: entries[1].id)
        // SwiftUI can deliver the old row's exit after the new row's entry.
        store.endPreview(id: entries[0].id)

        try await Task.sleep(for: .milliseconds(160))

        XCTAssertTrue(store.isExpanded)
        XCTAssertEqual(store.selectedEntryID, entries[1].id)
        store.stopSync()
    }

    @MainActor
    func testLeavingCurrentRowCancelsItsPreview() async throws {
        let store = PullRequestStore()
        store.loadPreviewData()
        let entry = try XCTUnwrap(store.railEntries.first)
        store.previewEntry(id: entry.id)
        store.endPreview(id: entry.id)

        try await Task.sleep(for: .milliseconds(160))

        XCTAssertFalse(store.isExpanded)
        XCTAssertNil(store.hoveredEntryID)
        store.stopSync()
    }
}
