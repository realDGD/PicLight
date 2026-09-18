import AppKit

/// Owns one viewer window and its view controller. One visible viewer equals one
/// top-level `NSWindow`; all hover UI stays inside it.
@MainActor
public final class ViewerWindowController: NSWindowController {
    public let viewerViewController: ViewerViewController

    private var drawerButton: NSButton?
    private var drawerAccessory: NSTitlebarAccessoryViewController?

    public convenience init() {
        self.init(viewer: ViewerViewController())
    }

    /// Builds the window around a caller-supplied viewer. The viewer is where the
    /// decode seams live (decoder, thumbnails, dimension probe), so this is how a
    /// test drives a window through a stub instead of the real ImageIO stack.
    public init(viewer: ViewerViewController) {
        let contentRect = WindowPlacementStore.defaultFrame(
            size: AppSettings.shared.lastWindowSize ?? CGSize(width: 960, height: 680),
            visibleFrame: NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let window = ViewerWindow(contentRect: contentRect)
        self.viewerViewController = viewer
        super.init(window: window)
        window.contentViewController = viewerViewController
        window.delegate = self
        viewerViewController.onDescriptorAvailable = { [weak self] descriptor in
            self?.applyImageSizedFrameIfNeeded(imagePixels: descriptor.displayPixelSize)
        }
        viewerViewController.onTitleChanged = { [weak self] name in
            self?.window?.title = name ?? "PicLight"
        }
        viewerViewController.onDrawerOpenChanged = { [weak self] open in
            self?.updateDrawerButton(open: open)
        }
        installDrawerTitlebarButton()
        window.setFrame(contentRect, display: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Drawer control in the titlebar

    /// The drawer opens and closes from a button beside the traffic lights, the way
    /// a sidebar does in a document window.
    private func installDrawerTitlebarButton() {
        // The accessory *is* the button, with an explicit frame: a container view with
        // no intrinsic size is laid out zero-width by the titlebar, which clipped the
        // button away entirely and made it invisible.
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: Self.drawerButtonSize.width,
                                            height: Self.drawerButtonSize.height))
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggleDrawerFromTitlebar)
        drawerButton = button

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = button
        window?.addTitlebarAccessoryViewController(accessory)
        drawerAccessory = accessory
        updateDrawerButton(open: viewerViewController.isDrawerOpen)
    }

    /// Size of the titlebar drawer control.
    static let drawerButtonSize = NSSize(width: 30, height: 22)

    fileprivate func updateDrawerButton(open: Bool) {
        let symbol = NSImage(
            systemSymbolName: open ? "rectangle.lefthalf.inset.filled" : "sidebar.left",
            accessibilityDescription: open ? "关闭左栏" : "打开左栏"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        drawerButton?.image = symbol
        drawerButton?.toolTip = open ? "关闭左栏" : "打开左栏"
        drawerButton?.setAccessibilityLabel(open ? "关闭左栏" : "打开左栏")
        drawerButton?.contentTintColor = open ? .controlAccentColor : nil
    }

    @objc private func toggleDrawerFromTitlebar() {
        viewerViewController.toggleDrawer()
    }

    /// The titlebar drawer button, for tests.
    var drawerTitlebarButton: NSButton? { drawerButton }

    /// Makes an existing viewer visible and key. Creating a controller is not the
    /// same thing as showing it: a bare launch, a Dock reopen and a file open all
    /// end here, so the "is there a window on screen?" question has one answer.
    public func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    public func open(url: URL) {
        viewerViewController.open(url: url)
        present()
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
        // The titlebar is AppKit's now, so the content area already excludes it;
        // only the viewer's own bottom chrome needs room.
        let insets = NSEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)
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
