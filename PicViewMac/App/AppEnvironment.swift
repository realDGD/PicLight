import AppKit

/// Holds app-wide services so the delegate stays thin.
@MainActor
public final class AppEnvironment {
    public static let shared = AppEnvironment()

    public let settings = AppSettings.shared
    public let shortcuts = ShortcutStore.shared
    public let fileOpener = FileOpenCoordinator()

    private var windowControllers: [ViewerWindowController] = []

    public init() {
        fileOpener.behaviorProvider = { [weak self] in
            self?.openBehaviorOverride ?? AppSettings.shared.openBehavior
        }
        fileOpener.openHandler = { [weak self] url, behavior in
            self?.open(url: url, behavior: behavior)
        }
    }

    public var mostRecentViewer: ViewerWindowController? {
        windowControllers.last { $0.window?.isVisible == true } ?? windowControllers.last
    }

    public func newViewerWindow() -> ViewerWindowController {
        let controller = ViewerWindowController()
        // Deterministic cascade so new windows never exactly overlap.
        if let window = controller.window,
           let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
           let base = windowControllers.last?.window?.frame {
            let frame = WindowPlacementStore.cascadedFrame(base: base, index: windowControllers.count,
                                                           visibleFrame: visible)
            window.setFrame(frame, display: false)
        }
        windowControllers.append(controller)
        return controller
    }

    public func open(url: URL, behavior: OpenBehavior? = nil) {
        let resolved = behavior ?? openBehaviorOverride ?? settings.openBehavior
        switch resolved {
        case .newWindow:
            let controller = newViewerWindow()
            controller.open(url: url)
        case .reuseCurrent:
            if let controller = mostRecentViewer {
                controller.open(url: url)
            } else {
                let controller = newViewerWindow()
                controller.open(url: url)
            }
        }
    }

    public var hasVisibleViewer: Bool {
        windowControllers.contains { $0.window?.isVisible == true }
    }

    // MARK: - Test-facing surface

    /// Lets tests pin the configured default instead of mutating real user defaults.
    var openBehaviorOverride: OpenBehavior?

    var viewerCount: Int { windowControllers.count }

    var viewerWindowControllers: [ViewerWindowController] { windowControllers }

    var currentFileNames: [String] {
        windowControllers.compactMap { $0.viewerViewController.session.currentItem?.displayName }
    }

    var firstErrorMessage: String? {
        windowControllers.first?.viewerViewController.viewerState.errorMessage
    }

    func performInFirstViewer(_ command: ViewerCommand) {
        windowControllers.first?.viewerViewController.perform(command)
    }
}
