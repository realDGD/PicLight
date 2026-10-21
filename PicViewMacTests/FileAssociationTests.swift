import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PicViewMac

@MainActor
final class FileAssociationTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/PicLight.app")
    private let otherURL = URL(fileURLWithPath: "/System/Applications/Preview.app")

    func testFormatsCoverExactlyTheSupportedExtensionsAndGroupAliases() {
        XCTAssertEqual(Set(ImageFileFormat.allCases.flatMap(\.filenameExtensions)),
                       SupportedImageTypes.requiredExtensions)
        XCTAssertEqual(ImageFileFormat.jpeg.filenameExtensions, ["jpg", "jpeg"])
        XCTAssertEqual(ImageFileFormat.tiff.filenameExtensions, ["tif", "tiff"])
        XCTAssertEqual(Set(ImageFileFormat.allCases.map { $0.contentType.identifier }),
                       Set(SupportedImageTypes.requiredContentTypes.map(\.identifier)))
    }

    func testReadingStatusAndSelectingNothingNeverChangesDefaults() async throws {
        let workspace = AssociationWorkspaceStub()
        workspace.handlers[.png] = otherURL
        let service = FileAssociationService(workspace: workspace, applicationURL: appURL)
        XCTAssertEqual(service.currentApplication(for: .png), otherURL)
        XCTAssertFalse(service.isAssociated(.png))
        let result = try await service.associate([])
        XCTAssertTrue(result.associated.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(workspace.requests.isEmpty)
    }

    func testOnlySelectedFormatsChangeAndAlreadyAssociatedFormatsAreSkipped() async throws {
        let workspace = AssociationWorkspaceStub()
        workspace.handlers[.png] = appURL
        workspace.handlers[.gif] = otherURL
        let service = FileAssociationService(workspace: workspace, applicationURL: appURL)
        let result = try await service.associate([.jpeg, .png])
        XCTAssertEqual(Set(result.associated), [.jpeg, .png])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(workspace.requests.map(\.format), [.jpeg])
        XCTAssertEqual(workspace.requests.map(\.applicationURL), [appURL])
        XCTAssertEqual(workspace.handlers[.gif], otherURL)
    }

    func testOneFailureDoesNotPreventTheRemainingFormatsFromBeingAssociated() async throws {
        let workspace = AssociationWorkspaceStub()
        workspace.failingFormats = [.jpeg]
        let service = FileAssociationService(workspace: workspace, applicationURL: appURL)
        let result = try await service.associate([.jpeg, .png, .webp])
        XCTAssertEqual(Set(result.associated), [.png, .webp])
        XCTAssertEqual(result.failures.map(\.format), [.jpeg])
        XCTAssertTrue(result.failures[0].message.contains("测试拒绝"))
        XCTAssertEqual(Set(workspace.requests.map(\.format)), [.jpeg, .png, .webp])
        XCTAssertFalse(service.isApplying)
    }

    func testSuccessRequiresTheSystemToReportThisCopyOfTheAppAsDefault() async throws {
        let workspace = AssociationWorkspaceStub()
        workspace.handlers[.png] = URL(fileURLWithPath: "/Volumes/Installer/PicLight.app")
        workspace.ignoreChanges = true
        let service = FileAssociationService(workspace: workspace, applicationURL: appURL)
        XCTAssertFalse(service.isAssociated(.png), "another copy is not the running app")
        let result = try await service.associate([.png])
        XCTAssertTrue(result.associated.isEmpty)
        XCTAssertEqual(result.failures.map(\.format), [.png])
    }

    func testUnbundledDevelopmentRunCannotChangeDefaults() async {
        let workspace = AssociationWorkspaceStub()
        let service = FileAssociationService(workspace: workspace, applicationURL: nil)
        XCTAssertFalse(service.canAssociate)
        do {
            _ = try await service.associate([.png])
            XCTFail("a command-line executable cannot become the default app")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("PicLight.app"))
        }
        XCTAssertTrue(workspace.requests.isEmpty)
    }

    func testASecondApplyCannotOverlapAPendingSystemConsentRequest() async throws {
        let workspace = AssociationWorkspaceStub()
        workspace.waitForConsent = true
        let service = FileAssociationService(workspace: workspace, applicationURL: appURL)
        let firstApply = Task { try await service.associate([.png]) }
        for _ in 0..<100 where workspace.pendingConsent == nil { await Task.yield() }
        XCTAssertNotNil(workspace.pendingConsent)
        XCTAssertTrue(service.isApplying)
        do {
            _ = try await service.associate([.jpeg])
            XCTFail("a second request must not queue another system prompt")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("等待"))
        }
        workspace.pendingConsent?.resume()
        workspace.pendingConsent = nil
        let result = try await firstApply.value
        XCTAssertEqual(result.associated, [.png])
        XCTAssertEqual(workspace.requests.map(\.format), [.png])
        XCTAssertFalse(service.isApplying)
    }

    func testAssociationPanelFitsTheEmbeddedTabSizeAndCanRenderAllRows() throws {
        TestAppKit.ensureApplication()
        let workspace = AssociationWorkspaceStub()
        let controller = FileAssociationViewController(
            service: FileAssociationService(workspace: workspace, applicationURL: appURL))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 512, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
        let root = controller.view
        let controls: [NSView] = Array(controller.formatCheckboxes.values)
            + Array(controller.statusLabels.values) + [controller.applyButton]
        for control in controls {
            let frame = root.convert(control.bounds, from: control)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(root.bounds.contains(frame), "every association control must remain reachable")
        }
        let statusEdges = controller.statusLabels.values.map {
            root.convert($0.bounds, from: $0).maxX
        }
        for edge in statusEdges {
            XCTAssertEqual(edge, statusEdges[0], accuracy: 0.5,
                           "current default apps form one aligned column")
        }
        if let path = ProcessInfo.processInfo.environment["PICLIGHT_ASSOCIATION_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    func testAssociationPanelRequiresAnExplicitSelectionAndDisplaysLiveStatus() throws {
        TestAppKit.ensureApplication()
        let workspace = AssociationWorkspaceStub()
        workspace.handlers[.png] = appURL
        let controller = FileAssociationViewController(
            service: FileAssociationService(workspace: workspace, applicationURL: appURL))
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.formatCheckboxes.count, ImageFileFormat.allCases.count)
        XCTAssertTrue(controller.formatCheckboxes.values.allSatisfy { $0.state == .off })
        XCTAssertFalse(controller.applyButton.isEnabled)
        XCTAssertTrue(controller.statusLabels[.png]?.stringValue.contains("已关联") == true)
        let checkbox = try XCTUnwrap(controller.formatCheckboxes[.jpeg])
        checkbox.state = .on
        checkbox.sendAction(try XCTUnwrap(checkbox.action), to: checkbox.target)
        XCTAssertTrue(controller.applyButton.isEnabled)
        XCTAssertTrue(workspace.requests.isEmpty, "checking a box is a draft, not a system write")
    }

    func testUnbundledAssociationPanelCannotApplyADraftSelection() throws {
        TestAppKit.ensureApplication()
        let workspace = AssociationWorkspaceStub()
        let controller = FileAssociationViewController(
            service: FileAssociationService(workspace: workspace, applicationURL: nil))
        controller.loadViewIfNeeded()
        let checkbox = try XCTUnwrap(controller.formatCheckboxes[.png])
        checkbox.state = .on
        checkbox.sendAction(try XCTUnwrap(checkbox.action), to: checkbox.target)
        XCTAssertFalse(controller.applyButton.isEnabled)
        XCTAssertTrue(workspace.requests.isEmpty)
        let feedback = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(feedback.string.contains("PicLight.app"))
    }

    func testApplyReportsPartialFailuresAndKeepsTheDraftSelection() throws {
        TestAppKit.ensureApplication()
        let workspace = AssociationWorkspaceStub()
        workspace.failingFormats = [.jpeg]
        let service = FileAssociationService(workspace: workspace, applicationURL: appURL)
        let controller = FileAssociationViewController(service: service)
        controller.loadViewIfNeeded()
        for format in [ImageFileFormat.jpeg, .png] {
            let checkbox = try XCTUnwrap(controller.formatCheckboxes[format])
            checkbox.state = .on
            checkbox.sendAction(try XCTUnwrap(checkbox.action), to: checkbox.target)
        }
        controller.applyButton.sendAction(try XCTUnwrap(controller.applyButton.action),
                                         to: controller.applyButton.target)
        let deadline = Date().addingTimeInterval(2)
        while (workspace.requests.count < 2 || service.isApplying) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(workspace.requests.map(\.format), [.jpeg, .png])
        XCTAssertTrue(controller.applyButton.isEnabled)
        XCTAssertTrue(controller.formatCheckboxes.values.allSatisfy(\.isEnabled))
        XCTAssertEqual(controller.formatCheckboxes[.jpeg]?.state, .on)
        XCTAssertEqual(controller.formatCheckboxes[.png]?.state, .on)
        XCTAssertTrue(controller.statusLabels[.png]?.stringValue.contains("已关联") == true)
        let feedback = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(feedback.string.contains("已关联 1"))
        XCTAssertTrue(feedback.string.contains("JPEG"))
        XCTAssertTrue(feedback.string.contains("测试拒绝"))
    }

    func testSettingsAssociationsAreAPeerPaneWithAllControlsVisible() throws {
        TestAppKit.ensureApplication()
        let controller = SettingsWindowController()
        defer { controller.close() }
        let viewController = try XCTUnwrap(controller.window?.contentViewController
                                            as? SettingsViewController)
        viewController.loadViewIfNeeded()
        XCTAssertEqual(viewController.paneTitlesForTesting,
                       ["通用", "看图", "高级", "快捷键", "格式关联", "关于"])
        viewController.selectPane("格式关联")
        viewController.view.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(viewController.children.compactMap { $0 as? FileAssociationViewController }.first)
        XCTAssertTrue(viewController.associationPane === panel.view)
        let container = viewController.associationPane
        for control in Array(panel.formatCheckboxes.values) + [panel.applyButton] {
            let frame = container.convert(control.bounds, from: control)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(container.bounds.contains(frame), "\(control.title) must fit the pane")
        }
        // Folder access lives in the viewer's 打开 pane; it must not be duplicated here.
        viewController.selectPane("看图")
        viewController.selectViewerSubPane("浏览")
        viewController.view.layoutSubtreeIfNeeded()
        let browse = try XCTUnwrap(viewController.viewerSubPaneView("浏览"))
        XCTAssertFalse(descendants(of: browse).compactMap { $0 as? NSButton }
            .contains { $0.title == "格式关联…" })
        XCTAssertNil(controller.window?.attachedSheet)
    }

    func testSelectingAssociationPaneRefreshesHandlersWithoutApplyingOrResettingDraft() throws {
        TestAppKit.ensureApplication()
        let workspace = AssociationWorkspaceStub()
        let panel = FileAssociationViewController(
            service: FileAssociationService(workspace: workspace, applicationURL: appURL))
        let settings = SettingsViewController(fileAssociationController: panel)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = settings

        workspace.handlers[.png] = appURL
        settings.selectPane("格式关联")
        XCTAssertEqual(panel.statusLabels[.png]?.stringValue, "PicLight · 已关联",
                       "entering the pane reads the current system handler")
        let checkbox = try XCTUnwrap(panel.formatCheckboxes[.jpeg])
        checkbox.state = .on
        checkbox.sendAction(try XCTUnwrap(checkbox.action), to: checkbox.target)

        settings.selectPane("看图")
        workspace.handlers[.png] = URL(fileURLWithPath: "/Applications/ExternalViewer.app")
        settings.selectPane("格式关联")
        XCTAssertEqual(panel.statusLabels[.png]?.stringValue, "当前：ExternalViewer",
                       "returning to the pane refreshes a handler changed elsewhere")
        XCTAssertEqual(checkbox.state, .on, "refreshing preserves the draft")
        XCTAssertTrue(panel.applyButton.isEnabled)
        XCTAssertTrue(workspace.requests.isEmpty, "switching panes must never apply associations")
        XCTAssertNil(window.attachedSheet)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class AssociationWorkspaceStub: FileAssociationWorkspace {
    struct Request {
        let format: ImageFileFormat
        let applicationURL: URL
    }
    var handlers: [ImageFileFormat: URL] = [:]
    var requests: [Request] = []
    var failingFormats: Set<ImageFileFormat> = []
    var ignoreChanges = false
    var waitForConsent = false
    var pendingConsent: CheckedContinuation<Void, Never>?

    func defaultApplication(for contentType: UTType) -> URL? {
        guard let format = ImageFileFormat.allCases.first(where: { $0.contentType == contentType })
        else { return nil }
        return handlers[format]
    }

    func setDefaultApplication(at applicationURL: URL, for contentType: UTType) async throws {
        let format = ImageFileFormat.allCases.first { $0.contentType == contentType }!
        requests.append(Request(format: format, applicationURL: applicationURL))
        if waitForConsent {
            await withCheckedContinuation { pendingConsent = $0 }
        }
        if failingFormats.contains(format) {
            throw NSError(domain: "FileAssociationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "测试拒绝"])
        }
        if !ignoreChanges { handlers[format] = applicationURL }
    }
}
