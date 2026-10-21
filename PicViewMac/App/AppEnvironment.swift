import AppKit

/// Holds app-wide services so the delegate stays thin.
@MainActor
public final class AppEnvironment {
    public static let shared = AppEnvironment()

    public let settings = AppSettings.shared
    public let shortcuts = ShortcutStore.shared
    public let fileOpener = FileOpenCoordinator()
    let folderAccess = FolderAccessStore.shared

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

    /// Creates a viewer window and, by default, presents it. Callers never have
    /// to remember `showWindow` themselves; pass `show: false` only when the
    /// window is about to be opened with a file, which presents it anyway.
    @discardableResult
    public func newViewerWindow(show: Bool = true) -> ViewerWindowController {
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
        if show { controller.present() }
        return controller
    }

    /// Bare launch and Dock reopen: always end up with a visible viewer.
    @discardableResult
    public func presentNewViewerWindow() -> ViewerWindowController {
        newViewerWindow(show: true)
    }

    /// The window a file belongs in when one of them is still empty.
    ///
    /// An empty viewer is a placeholder the user is looking at — the window the app opens with, before
    /// anything is in it. A file opened there belongs *in it*, whether it arrived from Finder, from the
    /// Open panel or by drag and drop, and whatever the "打开文件" setting says: that setting is about
    /// what to do when a picture is already on screen, and honouring it here left the empty window
    /// stranded beside a new one (reported: opening a file from the empty window always produced a
    /// second window).
    ///
    /// A window that is *loading* is not empty: its picture is on its way, and replacing it would throw
    /// away a decode the user is waiting for.
    private func emptyViewerWindow() -> ViewerWindowController? {
        // "Empty placeholder" is narrow on purpose: a window that has already been handed a file is not
        // one, even in the moment before its picture arrives — otherwise the second file of a multi-file
        // open would land in the window the first one is still loading into (measured: three opens, one
        // window, and only the last file visible).
        let candidates = windowControllers.filter {
            $0.window?.isVisible == true && !$0.isShowingPicture && !$0.hasReceivedFileRequest
        }
        if let key = candidates.first(where: { $0.window?.isKeyWindow == true }) { return key }
        return candidates.first
    }

    public func open(url: URL, behavior: OpenBehavior? = nil) {
        if let empty = emptyViewerWindow() {
            empty.noteFileRequested()
            empty.open(url: url)
            return
        }
        let resolved = behavior ?? openBehaviorOverride ?? settings.openBehavior
        switch resolved {
        case .newWindow:
            // Created without showing: `open(url:)` presents it, so a file open
            // never flashes an empty window first.
            let controller = newViewerWindow(show: false)
            controller.noteFileRequested()
            controller.open(url: url)
        case .reuseCurrent:
            if let controller = mostRecentViewer {
                controller.noteFileRequested()
                controller.open(url: url)
            } else {
                let controller = newViewerWindow(show: false)
                controller.noteFileRequested()
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
