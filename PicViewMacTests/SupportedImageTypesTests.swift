import XCTest
@testable import PicViewMac

final class SupportedImageTypesTests: XCTestCase {
    func testRequiredExtensionsAreCandidates() {
        for ext in ["bmp", "gif", "ico", "png", "jpg", "jpeg", "tif", "tiff", "webp"] {
            XCTAssertTrue(SupportedImageTypes.isCandidate(URL(fileURLWithPath: "/tmp/a.\(ext)")), ext)
        }
    }

    func testUppercaseExtensionsAreCandidates() {
        for ext in ["BMP", "GIF", "ICO", "PNG", "JPG", "JPEG", "TIF", "TIFF", "WEBP"] {
            XCTAssertTrue(SupportedImageTypes.isCandidate(URL(fileURLWithPath: "/tmp/a.\(ext)")), ext)
        }
    }

    func testUnsupportedExtensionsAreRejected() {
        for ext in ["pdf", "txt", "mp4", "heic", "raw", "svg"] {
            XCTAssertFalse(SupportedImageTypes.isCandidate(URL(fileURLWithPath: "/tmp/a.\(ext)")), ext)
        }
    }

    @MainActor
    func testFileOpenCoordinatorForwardsOnlySupportedFiles() {
        let coordinator = FileOpenCoordinator()
        var opened: [URL] = []
        coordinator.openHandler = { url, _ in opened.append(url) }
        coordinator.open(urls: [
            URL(fileURLWithPath: "/tmp/a.png"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
            URL(fileURLWithPath: "/tmp/c.WEBP"),
        ], behavior: .newWindow)
        XCTAssertEqual(opened.map(\.lastPathComponent), ["a.png", "c.WEBP"])
    }

    @MainActor
    func testFirstFileHonorsBehaviorAndExtraFilesAlwaysGetNewWindows() {
        let coordinator = FileOpenCoordinator()
        var behaviors: [OpenBehavior] = []
        coordinator.openHandler = { _, behavior in behaviors.append(behavior) }
        coordinator.open(urls: [URL(fileURLWithPath: "/tmp/a.png"),
                                URL(fileURLWithPath: "/tmp/b.png")],
                         behavior: .reuseCurrent)
        XCTAssertEqual(behaviors, [.reuseCurrent, .newWindow])
    }

    @MainActor
    func testModifierInversionFlipsTheConfiguredDefault() {
        XCTAssertEqual(OpenBehavior.newWindow.inverted, .reuseCurrent)
        XCTAssertEqual(OpenBehavior.reuseCurrent.inverted, .newWindow)
    }
}
