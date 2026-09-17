import AppKit

/// Owns one viewer window and its view controller. One visible viewer equals one
/// top-level `NSWindow`; all hover UI stays inside it.
@MainActor
public final class ViewerWindowController: NSWindowController {
    public let viewerViewController: ViewerViewController

    public init() {
        let contentRect = WindowPlacementStore.defaultFrame(
            size: AppSettings.shared.lastWindowSize ?? CGSize(width: 960, height: 680),
            visibleFrame: NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let window = ViewerWindow(contentRect: contentRect)
        self.viewerViewController = ViewerViewController()
        super.init(window: window)
        window.contentViewController = viewerViewController
        window.delegate = self
        viewerViewController.onDescriptorAvailable = { [weak self] descriptor in
            self?.applyImageSizedFrameIfNeeded(imagePixels: descriptor.displayPixelSize)
        }
        window.setFrame(contentRect, display: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func open(url: URL) {
        viewerViewController.open(url: url)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Remembers the content size only; a transient full-screen frame is never stored.
    private func rememberContentSize() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        AppSettings.shared.lastWindowSize = window.contentLayoutRect.size
    }

    public func applyImageSizedFrameIfNeeded(imagePixels: CGSize) {
        guard AppSettings.shared.windowSizing == .fitImageToScreen,
              let window, !window.styleMask.contains(.fullScreen) else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visible else { return }
        let insets = NSEdgeInsets(top: TopHoverBarView.height, left: 0, bottom: 40, right: 0)
        let frame = WindowPlacementStore.imageSizedFrame(imagePixels: imagePixels,
                                                        chromeInsets: insets, visibleFrame: visible)
        window.setFrame(frame, display: true)
    }
}

extension ViewerWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        rememberContentSize()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        rememberContentSize()
    }

    public func windowDidResize(_ notification: Notification) {
        rememberContentSize()
    }
}
