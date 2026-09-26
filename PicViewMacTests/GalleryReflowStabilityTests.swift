import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// The gallery must not *blank* a thumbnail it already has while a sharper one is on the way.
///
/// The report: dragging the toolbar's size slider made the grid flash, and the flashing stopped
/// after a few drags. The cause is a resolution upgrade that throws the displayable tier away
/// before the sharper decode exists — every cell that a reflow then re-materializes finds nothing
/// in the gallery's window and draws empty until the decode lands. The settle happens to be what
/// issues the upgrade, so a second drag (the "few drags" of the report) is what shows the blanks.
@MainActor
final class GalleryReflowStabilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func item(_ index: Int) -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/tmp/gallery-stability/img-\(index).png"),
                   pixelSize: CGSize(width: 2, height: 2))
    }

    private func solid(_ side: Int, red: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func presentOffScreen(_ view: NSView,
                                  size: NSSize = NSSize(width: 1200, height: 800)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    /// The reproduction: deliver a tier, settle the slider larger (which drops that tier and asks
    /// for a sharper one), then reflow again before the sharper decode has arrived. No cell that had
    /// a thumbnail may be blank.
    func testAReflowDuringAnUpgradeKeepsTheThumbnailItAlreadyHas() throws {
        let items = (0..<12).map { item($0) }
        let host = GalleryAuditHost(items: items,
                                    directory: URL(fileURLWithPath: "/tmp/gallery-stability"))
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)

        // The first tier arrives by hand, so the grid is showing real thumbnails.
        XCTAssertFalse(host.completions.isEmpty, "the first load asked for thumbnails")
        for entry in host.completions {
            entry.completion(entry.index, solid(320, red: 0.2))
        }
        pump(0.1)
        let grid = browser.view.gallery
        let deliveredBefore = grid.deliveredPathsForTesting
        XCTAssertFalse(deliveredBefore.isEmpty, "precondition: a tier is delivered and on screen")

        // Enlarge: geometry now, sharper pixels at the settle. The host never completes the
        // sharper request, so from here on the upgrade is in flight and nothing has arrived.
        let requestsBefore = host.requests.count
        browser.view.onThumbnailSizeChanged?(320)
        browser.view.onThumbnailSizeSettled?(320)
        pump(0.6)
        let upgrades = host.requests.dropFirst(requestsBefore).filter { $0.maxPixelSize >= 640 }
        XCTAssertFalse(upgrades.isEmpty,
                       "precondition: the settle asked for a sharper tier, and its completions "
                       + "are still uncalled, so the sharper pixels have not arrived")

        // The next drag: cells that left the large-size window come back.
        browser.view.onThumbnailSizeChanged?(80)
        pump(0.2)
        grid.layoutSubtreeIfNeeded()

        var blanked: [Int] = []
        for (index, cell) in grid.visibleCells
        where deliveredBefore.contains(items[index].url.path) {
            if cell.imageForTesting == nil { blanked.append(index) }
        }
        XCTAssertTrue(blanked.isEmpty,
                      "a reflow must keep the thumbnail the grid already has; indexes "
                      + "\(blanked) went blank while the sharper decode was still in flight")
    }

    /// The other half: the same drag must not start a decode per reflowed cell either. The live
    /// reflow is geometry only; the settle is what escalates the tier.
    func testAReflowDuringAnUpgradeStartsNoNewDecodes() throws {        let items = (0..<12).map { item($0) }
        let host = GalleryAuditHost(items: items,
                                    directory: URL(fileURLWithPath: "/tmp/gallery-stability"))
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)
        for entry in host.completions {
            entry.completion(entry.index, solid(320, red: 0.2))
        }
        pump(0.1)

        browser.view.onThumbnailSizeChanged?(320)
        browser.view.onThumbnailSizeSettled?(320)
        pump(0.6)
        let requestsAfterSettle = browser.thumbnailRequestCount

        // A long second drag, back down to the minimum.
        for step in stride(from: CGFloat(320), through: 80, by: -8) {
            browser.view.onThumbnailSizeChanged?(step)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(browser.thumbnailRequestCount, requestsAfterSettle,
                       "moving the slider must not decode anything; only settling may")
    }

    /// A drag holds the retention window open. The cap is a function of the window size, and growing
    /// the thumbnails shrinks the window — so a trim in the middle of the gesture would evict exactly
    /// the thumbnails the same drag needs again on the way back, and the cells coming back would draw
    /// blank until they were decoded again.
    func testADragHoldsTheRetentionWindowOpenUntilItSettles() throws {
        let items = (0..<400).map { item($0) }
        let host = GalleryAuditHost(items: items,
                                    directory: URL(fileURLWithPath: "/tmp/gallery-stability"))
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.2)
        let grid = browser.view.gallery

        // The drag is in progress, and the window is far past the retention cap.
        browser.view.onThumbnailSizeChanged?(160)
        for entry in items {
            grid.noteDelivered(solid(64, red: 0.2), pixelSize: 320, versionToken: "t",
                               for: entry.url)
        }
        let held = grid.deliveredImageCountForTesting
        XCTAssertEqual(held, items.count, "a paused window keeps everything it is handed")

        // The reflow of the drag must not trim it down to the window it is passing through.
        browser.view.onThumbnailSizeChanged?(320)
        grid.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.deliveredImageCountForTesting, held,
                       "a live reflow must not evict the retained window")

        // The settle ends the gesture and trims to the window it ended on.
        browser.view.onThumbnailSizeSettled?(320)
        XCTAssertLessThan(grid.deliveredImageCountForTesting, held,
                          "the settle trims to the window the drag ended on")
    }
}
