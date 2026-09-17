import XCTest
@testable import PicViewMac

@MainActor
final class FolderSessionTests: XCTestCase {
    private func items(_ names: [String]) -> [FolderItem] {
        names.map { FolderItem(url: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    func testInitialPositionAndNavigation() {
        let session = FolderSession(items: items(["1.jpg", "2.jpg", "3.jpg"]))
        XCTAssertEqual(session.currentItem?.displayName, "1.jpg")
        XCTAssertEqual(session.positionDescription, "1 / 3")
        session.goNext()
        XCTAssertEqual(session.currentItem?.displayName, "2.jpg")
        session.goPrevious()
        XCTAssertEqual(session.currentItem?.displayName, "1.jpg")
        XCTAssertEqual(session.positionDescription, "1 / 3")
    }

    func testNavigationStopsAtBothEnds() {
        let session = FolderSession(items: items(["1.jpg", "2.jpg"]))
        session.goPrevious()
        XCTAssertEqual(session.currentItem?.displayName, "1.jpg")
        session.goNext()
        session.goNext()
        XCTAssertEqual(session.currentItem?.displayName, "2.jpg")
        XCTAssertEqual(session.positionDescription, "2 / 2")
    }

    func testRescanKeepsCurrentFileIdentityAcrossResort() {
        let session = FolderSession(items: items(["1.jpg", "2.jpg", "3.jpg"]))
        session.select(index: 2)
        XCTAssertEqual(session.currentItem?.displayName, "3.jpg")
        // New file inserted before the current one: index changes, identity does not.
        session.setItems(items(["0.jpg", "1.jpg", "2.jpg", "3.jpg"]))
        XCTAssertEqual(session.currentItem?.displayName, "3.jpg")
        XCTAssertEqual(session.positionDescription, "4 / 4")
    }

    func testRescanFollowsRenameThroughStableFileIdentity() {
        let session = FolderSession(items: items(["a.jpg", "b.jpg"]))
        let renamed = FolderItem(url: URL(fileURLWithPath: "/tmp/b-renamed.jpg"))
        session.setItems([items(["a.jpg"])[0], renamed], preferredIdentity: renamed.id)
        XCTAssertEqual(session.currentItem?.displayName, "b-renamed.jpg")
    }

    func testExternalRemovalSelectsNextThenPreviousThenEmpty() {
        // Removing from the middle prefers the image that took the slot.
        let middle = FolderSession(items: items(["1.jpg", "2.jpg", "3.jpg"]))
        middle.select(index: 1)
        middle.applyExternalRemoval(of: middle.items[1].id)
        XCTAssertEqual(middle.currentItem?.displayName, "3.jpg")

        // Removing the first image selects the new first image.
        let first = FolderSession(items: items(["1.jpg", "2.jpg"]))
        first.select(index: 0)
        first.applyExternalRemoval(of: first.items[0].id)
        XCTAssertEqual(first.currentItem?.displayName, "2.jpg")

        // Removing the last image falls back to the previous one.
        let last = FolderSession(items: items(["1.jpg", "2.jpg"]))
        last.select(index: 1)
        last.applyExternalRemoval(of: last.items[1].id)
        XCTAssertEqual(last.currentItem?.displayName, "1.jpg")

        // Removing everything leaves a usable empty state.
        let single = FolderSession(items: items(["only.jpg"]))
        single.applyExternalRemoval(of: single.items[0].id)
        XCTAssertNil(single.currentItem)
        XCTAssertTrue(single.isEmpty)
        XCTAssertEqual(single.positionDescription, "— / 0")
    }

    func testSmartSelectionAfterTrashOfLastImageFallsBackToPrevious() {
        let session = FolderSession(items: items(["1.jpg", "2.jpg"]))
        session.select(index: 1)
        session.removeCurrentWithSmartSelection(identity: session.currentItem?.id)
        XCTAssertEqual(session.currentItem?.displayName, "1.jpg")
        XCTAssertEqual(session.positionDescription, "1 / 1")
    }

    func testSelectByURLAndIdentity() {
        let session = FolderSession(items: items(["1.jpg", "2.jpg"]))
        XCTAssertTrue(session.select(url: URL(fileURLWithPath: "/tmp/2.jpg")))
        XCTAssertEqual(session.currentIndex, 1)
        XCTAssertTrue(session.select(identity: session.items[0].id))
        XCTAssertEqual(session.currentIndex, 0)
        XCTAssertFalse(session.select(url: URL(fileURLWithPath: "/tmp/missing.jpg")))
    }

    func testEmptyFolderStateStaysUsable() {
        let session = FolderSession(items: [])
        XCTAssertNil(session.currentItem)
        XCTAssertNil(session.goNext())
        XCTAssertNil(session.goPrevious())
        XCTAssertEqual(session.positionDescription, "— / 0")
    }

    func testRemoveCurrentIsIgnoredForUnknownIdentity() {
        let session = FolderSession(items: items(["1.jpg", "2.jpg"]))
        session.applyExternalRemoval(of: FileIdentity(url: URL(fileURLWithPath: "/tmp/ghost.jpg")))
        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.currentItem?.displayName, "1.jpg")
    }
}
