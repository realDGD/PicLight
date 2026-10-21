import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// The gallery's hot path: the geometry that used to be recomputed per delivery, and the visible-row
/// query that used to walk the whole folder.
///
/// Run it in Release for the numbers worth recording:
///
///     swift test -c release --filter GalleryPerformanceTests
///
/// It asserts *structure* — work that must not scale with the folder, and the equivalence of the
/// binary search to the linear scan it replaced — and prints the timings. A wall-clock threshold
/// would fail on a Debug run or a loaded machine for reasons that have nothing to do with this code.
@MainActor
final class GalleryPerformanceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let started = Date()
        body()
        return Date().timeIntervalSince(started) * 1000
    }

    /// The pure layout function, at the folder sizes the report measured.
    func testLayoutCostByFolderSize() {
        for count in [1_000, 10_000, 50_000] {
            let aspects = (0..<count).map { CGFloat(0.5 + Double($0 % 20) / 10) }
            var rows = 0
            let uniform = milliseconds {
                rows = GalleryLayout.uniformRows(aspects: aspects, containerWidth: 1_000,
                                                 thumbnailSize: 160).count
            }
            let adaptive = milliseconds {
                _ = GalleryLayout.adaptiveRows(aspects: aspects, containerWidth: 1_000,
                                               thumbnailSize: 160).count
            }
            print("GALLERY-PERF \(count) items: uniformRows=\(String(format: "%.3f", uniform)) ms "
                + "(\(rows) rows), adaptiveRows=\(String(format: "%.3f", adaptive)) ms")
        }
    }

    /// The visible-row query: the binary search must agree with the linear scan it replaced, and
    /// must not cost the whole folder.
    func testVisibleRowsMatchTheLinearScanAndDoNotScanTheFolder() {
        let rows = GalleryLayout.uniformRows(aspects: Array(repeating: 1.5, count: 50_000),
                                             containerWidth: 1_000, thumbnailSize: 160)
        XCTAssertGreaterThan(rows.count, 1_000, "precondition: a folder worth searching")

        let viewport = CGRect(x: 0, y: rows[rows.count / 2].frame.minY, width: 1_000, height: 700)
        let scanned = milliseconds {
            for _ in 0..<200 { _ = rows.filter { $0.frame.intersects(viewport) } }
        }
        let searched = milliseconds {
            for _ in 0..<200 { _ = GalleryLayout.visibleRows(in: viewport, of: rows) }
        }
        print("GALLERY-PERF visible rows over \(rows.count) rows ×200: "
            + "filter=\(String(format: "%.3f", scanned)) ms, "
            + "binarySearch=\(String(format: "%.3f", searched)) ms")

        // Equivalence, at the boundaries as well as the middle: this is why the search is allowed to
        // exist at all.
        let probes = [CGRect(x: 0, y: 0, width: 1_000, height: 700),
                      CGRect(x: 0, y: rows[0].frame.minY, width: 1_000, height: 1),
                      CGRect(x: 0, y: rows[rows.count / 3].frame.minY, width: 1_000, height: 2_000),
                      CGRect(x: 0, y: rows[rows.count - 1].frame.minY, width: 1_000, height: 700),
                      CGRect(x: 0, y: rows[rows.count - 1].frame.maxY + 100, width: 1_000, height: 700),
                      CGRect(x: 0, y: -5_000, width: 1_000, height: 700)]
        for probe in probes {
            XCTAssertEqual(GalleryLayout.visibleRows(in: probe, of: rows).map(\.cells.count),
                           rows.filter { $0.frame.intersects(probe) }.map(\.cells.count),
                           "the search and the scan must agree for \(probe)")
        }
    }

    /// A delivered thumbnail must not rebuild the folder's geometry in any configuration.
    func testDeliveriesDoNotRebuildGeometry() {
        let host = GalleryAuditHost(
            items: (0..<50_000).map {
                FolderItem(url: URL(fileURLWithPath: "/tmp/gallery-perf/img-\($0).png"),
                           pixelSize: CGSize(width: 2, height: 2))
            },
            directory: URL(fileURLWithPath: "/tmp/gallery-perf"))
        let browser = FolderBrowserViewController(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        TestAppKit.prepareForOffScreen(window)
        window.contentView = browser.view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        browser.reload()
        window.layoutIfNeeded()
        pump(0.3)

        let grid = browser.view.gallery
        let before = grid.rowsComputationCountForTesting
        let image = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                              bytesPerRow: 32 * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .makeImage()!
        let deliveries = milliseconds {
            for index in 0..<100 {
                grid.noteDelivered(image, pixelSize: 300, versionToken: "v",
                                   for: host.session.items[index].url)
            }
        }
        let rebuilt = grid.rowsComputationCountForTesting - before
        print("GALLERY-PERF 100 deliveries in a 50,000-item folder: "
            + "\(String(format: "%.3f", deliveries)) ms total "
            + "(\(String(format: "%.3f", deliveries / 100)) ms each), geometry rebuilds=\(rebuilt)")
        XCTAssertLessThanOrEqual(rebuilt, 1,
                                 "geometry is a function of four values, not of the delivery count")
    }
}
