import XCTest
import CryptoKit
import AppKit
import UniformTypeIdentifiers
@testable import PicViewMac

/// Every way a file can be opened must go through one coordinator and must not
/// leave stray windows behind.
@MainActor
final class OpenPathTests: XCTestCase {
    private var controllers: [ViewerWindowController] = []

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
        controllers = []
    }

    override func tearDown() async throws {
        controllers.forEach { $0.close() }
        controllers = []
        try await super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let directory = try Fixtures.makeScratchDirectory("open-paths")
        for name in ["a.png", "b.png", "c.jpg"] {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: Fixtures.url("corrupt.png"),
                                         to: directory.appendingPathComponent("ab-corrupt.png"))
        try Data("%PDF-1.4".utf8).write(to: directory.appendingPathComponent("notes.pdf"))
        return directory
    }

    private func visibleViewerWindows() -> [ViewerWindow] {
        NSApp.windows.compactMap { $0 as? ViewerWindow }.filter { $0.isVisible }
    }

    func testOpeningOneFileLeavesExactlyOneViewerWindow() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = AppEnvironment()
        defer { environment.viewerWindowControllers.forEach { $0.close() } }
        controllers = environment.viewerWindowControllers
        environment.open(url: directory.appendingPathComponent("a.png"), behavior: .newWindow)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        controllers = environment.viewerWindowControllers

        XCTAssertEqual(environment.viewerCount, 1,
                       "opening one file must create exactly one viewer, not an empty extra one")
        XCTAssertEqual(visibleViewerWindows().count, 1)
    }

    func testOpeningSeveralFilesCreatesOneViewerEach() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = AppEnvironment()
        defer { environment.viewerWindowControllers.forEach { $0.close() } }
        controllers = environment.viewerWindowControllers
        environment.open(url: directory.appendingPathComponent("a.png"), behavior: .newWindow)
        environment.open(url: directory.appendingPathComponent("b.png"), behavior: .newWindow)
        environment.open(url: directory.appendingPathComponent("c.jpg"), behavior: .newWindow)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(environment.viewerCount, 3)
        XCTAssertEqual(visibleViewerWindows().count, 3)
        let names = environment.currentFileNames
        XCTAssertEqual(Set(names), Set(["a.png", "b.png", "c.jpg"]),
                       "each window must show the file it was opened with, got \(names)")
    }

    func testReuseCurrentBehaviorDoesNotCreateASecondViewer() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = AppEnvironment()
        defer { environment.viewerWindowControllers.forEach { $0.close() } }
        environment.open(url: directory.appendingPathComponent("a.png"), behavior: .newWindow)
        try await Task.sleep(nanoseconds: 900_000_000)
        environment.open(url: directory.appendingPathComponent("b.png"), behavior: .reuseCurrent)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(environment.viewerCount, 1, "reuse-current must not open a second window")
        XCTAssertEqual(environment.currentFileNames, ["b.png"])
    }

    func testConfiguredDefaultAndExplicitInverseAreRespected() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = AppEnvironment()
        defer { environment.viewerWindowControllers.forEach { $0.close() } }

        // Configured default: open in a new window.
        environment.openBehaviorOverride = .newWindow
        environment.open(url: directory.appendingPathComponent("a.png"))
        try await Task.sleep(nanoseconds: 900_000_000)
        environment.open(url: directory.appendingPathComponent("b.png"))
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(environment.viewerCount, 2, "the configured default is a new window")

        // The explicit inverse command reuses the current window instead.
        environment.openBehaviorOverride = .reuseCurrent
        environment.open(url: directory.appendingPathComponent("c.jpg"))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(environment.viewerCount, 2, "the explicit inverse must not add a window")
        XCTAssertTrue(environment.currentFileNames.contains("c.jpg"))
    }

    func testUnsupportedFileProducesNoGhostViewer() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = AppEnvironment()
        defer { environment.viewerWindowControllers.forEach { $0.close() } }
        environment.fileOpener.open(url: directory.appendingPathComponent("notes.pdf"),
                                    behavior: .newWindow)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(environment.viewerCount, 0,
                       "an unsupported file must not open a window at all")
        XCTAssertEqual(visibleViewerWindows().count, 0)
    }

    func testCorruptSupportedFileOpensAWindowThatReportsTheError() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = AppEnvironment()
        defer { environment.viewerWindowControllers.forEach { $0.close() } }
        environment.open(url: directory.appendingPathComponent("ab-corrupt.png"), behavior: .newWindow)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(environment.viewerCount, 1,
                       "a corrupt but supported file still deserves a window with an error state")
        let message = environment.firstErrorMessage
        XCTAssertNotNil(message, "the viewer must report why the file could not be shown")
        XCTAssertTrue(message?.contains("ab-corrupt.png") == true,
                      "the error should name the file, got \(message ?? "nil")")
        // Navigation remains alive around the corrupt file.
        environment.performInFirstViewer(.nextImage)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(environment.firstErrorMessage,
                     "moving to a good file must clear the error state")
    }

    func testDeclaredFinderTypesMatchTheSupportedSet() {
        // The app declares these to Finder, so the two lists must not drift apart.
        XCTAssertEqual(SupportedImageTypes.declaredDocumentExtensions,
                       SupportedImageTypes.requiredExtensions.sorted())
        for ext in ["bmp", "gif", "ico", "png", "jpg", "jpeg", "tif", "tiff", "webp"] {
            XCTAssertTrue(SupportedImageTypes.requiredExtensions.contains(ext))
        }
        let declared = Set(SupportedImageTypes.requiredContentTypes.map(\.identifier))
        for ext in SupportedImageTypes.requiredExtensions {
            let type = UTType(filenameExtension: ext)
            XCTAssertNotNil(type, "\(ext) must resolve to a UTType")
            XCTAssertTrue(declared.contains(type?.identifier ?? ""),
                          "\(ext) resolves to \(type?.identifier ?? "nil"), which is not declared to Finder")
        }
        // Aliases share a type on purpose: jpg/jpeg and tif/tiff.
        XCTAssertEqual(declared.count, 7, "seven UTIs cover the nine extensions")
    }

    func testExtensionAliasesRouteToTheSameTypes() {
        // .jpg/.jpeg and .tif/.tiff are aliases of the same format families.
        XCTAssertTrue(SupportedImageTypes.isCandidate(URL(fileURLWithPath: "/tmp/x.jpg")))
        XCTAssertTrue(SupportedImageTypes.isCandidate(URL(fileURLWithPath: "/tmp/x.jpeg")))
        XCTAssertTrue(SupportedImageTypes.isCandidate(URL(fileURLWithPath: "/tmp/x.tif")))
        XCTAssertTrue(SupportedImageTypes.isCandidate(URL(fileURLWithPath: "/tmp/x.tiff")))

        let aliased = SupportedImageTypes.requiredContentTypes.map(\.identifier)
        XCTAssertTrue(aliased.contains("public.jpeg"))
        XCTAssertTrue(aliased.contains("public.tiff"))
        XCTAssertEqual(Set(aliased).count, aliased.count, "no duplicate UTIs are declared")
    }

    func testMultipleFilesFromOneDropEachGetAWindow() {
        let coordinator = FileOpenCoordinator()
        var received: [(String, OpenBehavior)] = []
        coordinator.openHandler = { url, behavior in received.append((url.lastPathComponent, behavior)) }
        coordinator.open(urls: [URL(fileURLWithPath: "/tmp/a.png"),
                                URL(fileURLWithPath: "/tmp/b.png"),
                                URL(fileURLWithPath: "/tmp/notes.pdf")],
                         behavior: .reuseCurrent)
        XCTAssertEqual(received.map(\.0), ["a.png", "b.png"],
                       "the unsupported file is dropped, the rest are opened")
        XCTAssertEqual(received.map(\.1), [.reuseCurrent, .newWindow],
                       "only the first file honors the configured behavior")
    }
}

/// Trash behavior and the promise that viewing never rewrites a source file.
@MainActor
final class TrashAndImmutabilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    private func makeFolder(names: [String]) throws -> URL {
        let directory = try Fixtures.makeScratchDirectory("trash")
        for name in names {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent(name))
        }
        return directory
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitForDecode(_ viewer: ViewerViewController, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testViewOperationsNeverRewriteTheSourceFile() async throws {
        let directory = try makeFolder(names: ["a.png"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.png")
        let before = try sha256(of: file)

        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.open(url: file)
        await waitForDecode(viewer)

        viewer.perform(.rotateClockwise)
        viewer.perform(.rotateCounterClockwise)
        viewer.perform(.toggleMirror)
        viewer.perform(.zoomActualPixels)
        viewer.perform(.zoomToFit)
        viewer.perform(.zoomDoubleFit)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(try sha256(of: file), before,
                       "rotate, mirror and zoom are view-only and must not touch the file")
    }

    func testTrashUsesTheSystemAPIAndSelectsTheNextImage() async throws {
        try await SharedSettingsScope.preservingSort(key: .filename, direction: .ascending) {

            let directory = try makeFolder(names: ["a.png", "b.png", "c.png"])
            defer { try? FileManager.default.removeItem(at: directory) }
            let viewer = ViewerViewController()
            _ = viewer.view
            viewer.open(url: directory.appendingPathComponent("b.png"))
            await waitForDecode(viewer)
            XCTAssertEqual(viewer.session.currentItem?.displayName, "b.png")

            viewer.perform(.moveToTrash)
            try await Task.sleep(nanoseconds: 600_000_000)

            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.png").path),
                           "the file must be gone from the folder")
            XCTAssertEqual(viewer.session.currentItem?.displayName, "c.png",
                           "deleting mid-folder prefers the next image")
            XCTAssertEqual(viewer.session.items.count, 2)
    
}
}

    func testTrashingTheLastImageFallsBackToThePreviousOne() async throws {
        let directory = try makeFolder(names: ["a.png", "b.png"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("b.png"))
        await waitForDecode(viewer)

        viewer.perform(.moveToTrash)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(viewer.session.currentItem?.displayName, "a.png")
        XCTAssertEqual(viewer.session.positionDescription, "1 / 1")
    }

    func testTrashingTheOnlyImageLeavesAnEmptyState() async throws {
        let directory = try makeFolder(names: ["only.png"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("only.png"))
        await waitForDecode(viewer)

        viewer.perform(.moveToTrash)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(viewer.session.isEmpty)
        XCTAssertNil(viewer.session.currentItem)
        XCTAssertNil(viewer.viewerState.errorMessage,
                     "an empty folder is a normal state, not an error")
    }

    func testAFailedTrashKeepsTheCurrentSelectionAndReportsWhy() async throws {
        try await SharedSettingsScope.preservingSort(key: .filename, direction: .ascending) {

            let directory = try makeFolder(names: ["a.png", "b.png"])
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: directory.path)
                try? FileManager.default.removeItem(at: directory)
            }
            let viewer = ViewerViewController()
            _ = viewer.view
            viewer.open(url: directory.appendingPathComponent("a.png"))
            await waitForDecode(viewer)
            XCTAssertEqual(viewer.session.currentItem?.displayName, "a.png")

            // Moving a file out of a directory requires write permission on the
            // directory, so this makes the Trash operation fail deterministically.
            try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                  ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                           ofItemAtPath: directory.path) }

            viewer.perform(.moveToTrash)
            try await Task.sleep(nanoseconds: 800_000_000)

            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.png").path),
                          "a failed Trash must leave the file alone")
            XCTAssertEqual(viewer.session.currentItem?.displayName, "a.png",
                           "a failed Trash must keep the current selection")
            XCTAssertEqual(viewer.session.items.count, 2)
            let message = viewer.viewerState.errorMessage ?? ""
            XCTAssertFalse(message.isEmpty, "a failed Trash must be reported non-modally")
            XCTAssertTrue(message.contains("废纸篓") || message.contains("Trash"),
                          "the message should name the Trash operation, got \(message)")

            // The viewer stays usable after the failure.
            viewer.perform(.nextImage)
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertEqual(viewer.session.currentItem?.displayName, "b.png")
    
}
}

    func testExternalRemovalOfTheLastFileLeavesNoStaleSelection() async throws {
        let directory = try makeFolder(names: ["a.png"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("a.png"))
        await waitForDecode(viewer)

        // Watcher-driven removal, not via Trash.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.png"))
        let deadline = Date().addingTimeInterval(6)
        while !viewer.session.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(viewer.session.isEmpty)
        XCTAssertNil(viewer.session.currentItem)
        XCTAssertEqual(viewer.session.positionDescription, "— / 0")
    }
}
