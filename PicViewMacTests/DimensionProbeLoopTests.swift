import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import PicViewMac

/// Two reports about the lazy dimension probe, both measured before they were fixed.
///
/// One unreadable image used to republish the whole list more than twenty times a second: the probe
/// could not tell "not read yet" from "cannot be read", so every reload asked it again. And choosing
/// 图像尺寸 while the probe was still running left the list in filename order forever, because
/// nothing re-applied the sort once the sizes arrived.
@MainActor
final class DimensionProbeLoopTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func writePNG(to url: URL, width: Int, height: Int, red: CGFloat) {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                          "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
    }

    private func presentOffScreen(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    /// The loop: a file whose header cannot be read must not keep the list republishing itself.
    ///
    /// The count is the measurement. One publish is the fill that worked; anything proportional to
    /// the 1.2 s the run loop is pumped is the loop.
    func testAnUnreadableImageIsProbedOnceRatherThanOnEveryReload() throws {
        let directory = try Fixtures.makeScratchDirectory("probe-loop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.png")
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: good)
        let unreadable = directory.appendingPathComponent("bad.png")
        try Data("this is not an image at all".utf8).write(to: unreadable)

        let host = GalleryAuditHost(items: [FolderItem(url: good), FolderItem(url: unreadable)],
                                    directory: directory)
        var publishes = 0
        host.session.onItemsChanged = { publishes += 1 }
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(1.2)

        XCTAssertNotNil(host.session.items.first { $0.displayName == "good.png" }?.pixelSize,
                        "the readable file's size is filled in")
        XCTAssertNil(host.session.items.first { $0.displayName == "bad.png" }?.pixelSize,
                     "an unreadable header stays unknown")
        XCTAssertLessThanOrEqual(publishes, 3,
                                 "the list is published once for the fill, not once per probe "
                                 + "(measured before: 22 publishes in 1.2 s)")
    }

    /// A file that becomes readable again is picked up the next time the folder is opened: the
    /// failure is remembered for a visit to the folder, not forever.
    func testAFailedHeaderIsReadAgainWhenTheFolderReopens() throws {
        let directory = try Fixtures.makeScratchDirectory("probe-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let late = directory.appendingPathComponent("late.png")
        try Data("not yet an image".utf8).write(to: late)
        // A sibling so the folder has a second item to change the list with.
        writePNG(to: directory.appendingPathComponent("other.png"), width: 20, height: 20, red: 0.4)

        let host = GalleryAuditHost(items: [FolderItem(url: late),
                                            FolderItem(url: directory.appendingPathComponent("other.png"))],
                                    directory: directory)
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.5)
        XCTAssertNil(host.session.items.first { $0.displayName == "late.png" }?.pixelSize)

        // The download finishes, and an unrelated file appears: a changed list is a new visit.
        writePNG(to: late, width: 40, height: 30, red: 0.9)
        writePNG(to: directory.appendingPathComponent("another.png"), width: 10, height: 10, red: 0.2)
        host.session.setItems([FolderItem(url: late),
                               FolderItem(url: directory.appendingPathComponent("other.png")),
                               FolderItem(url: directory.appendingPathComponent("another.png"))],
                              preferredIdentity: nil)
        browser.reload()
        pump(1.0)

        let size = host.session.items.first { $0.displayName == "late.png" }?.pixelSize
        XCTAssertEqual(size?.width, 40, "the repaired file is measured on the next visit")
    }

    /// The reported bug: choosing 图像尺寸 before the sizes arrive left the order alone forever.
    func testDimensionSortChosenWhileTheProbeRunsIsAppliedWhenTheSizesArrive() throws {
        let directory = try Fixtures.makeScratchDirectory("dimsort-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        writePNG(to: directory.appendingPathComponent("a-big.png"), width: 400, height: 300, red: 0.9)
        writePNG(to: directory.appendingPathComponent("z-small.png"), width: 40, height: 30, red: 0.1)

        SharedSettingsScope.preservingSort(key: .filename, direction: .ascending) {
            let host = GalleryAuditHost(
                items: ["a-big.png", "z-small.png"].map {
                    FolderItem(url: directory.appendingPathComponent($0))
                },
                directory: directory)
            let browser = FolderBrowserViewController(host: host)
            let window = presentOffScreen(browser.view)
            defer { window.close() }
            browser.reload()
            // Immediately: the probe's debounce has not elapsed, so every size is still unknown.
            browser.view.onSortKeyChanged?(.dimensions)
            pump(1.5)

            let names = host.session.items.map(\.displayName)
            let pixels = host.session.items.map { item in
                item.pixelSize.map { Int($0.width * $0.height) } ?? -1
            }
            XCTAssertEqual(pixels, [1_200, 120_000],
                           "the probe filled both sizes (small first)")
            XCTAssertEqual(names, ["z-small.png", "a-big.png"],
                           "and the order chosen before they arrived was applied to them")
        }
    }
}
