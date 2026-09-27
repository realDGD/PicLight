import AppKit

/// Owns one viewer window and its view controller. One visible viewer equals one
/// top-level `NSWindow`; all hover UI stays inside it.
@MainActor
public final class ViewerWindowController: NSWindowController {
    public let viewerViewController: ViewerViewController

    /// Whether this window has a picture to show — on screen, or still decoding. An empty window is a
    /// placeholder, and a file opened while one is up belongs in it (see `AppEnvironment.open`).
    public var isShowingPicture: Bool {
        viewerViewController.isShowingPicture
    }

    /// Whether this window has already been handed a file. A window that has is not the empty
    /// placeholder any more, even before its picture arrives: opening three files in a row must produce
    /// three windows, not one window that keeps replacing itself.
    public private(set) var hasReceivedFileRequest = false

    public func noteFileRequested() {
        hasReceivedFileRequest = true
    }

    private var drawerButton: NSButton?
    private var drawerAccessory: NSTitlebarAccessoryViewController?
    private var sizeAccessory: NSTitlebarAccessoryViewController?
    private let sizeLabel = NSTextField(labelWithString: "")

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
        viewerViewController.onSizeReadoutChanged = { [weak self] text in
            self?.updateSizeReadout(text)
        }
        viewerViewController.onTitleChanged = { [weak self] name in
            self?.window?.title = name ?? "PicLight"
        }
        viewerViewController.onDrawerOpenChanged = { [weak self] open in
            self?.updateDrawerButton(open: open)
        }
        // The button renders whichever left column is in force: the drawer in the image mode, the
        // folder tree while the browser is up.
        viewerViewController.onLeftColumnChanged = { [weak self] open in
            self?.updateDrawerButton(open: open)
        }
        // The titlebar mode is a window property, so the window applies it as soon as it exists.
        viewerViewController.onTitlebarModeNeeded = { [weak self] in
            self?.viewerViewController.applyTitlebarModeForWindow()
        }
        viewerViewController.applyTitlebarModeForWindow()
        installDrawerTitlebarButton()
        installSizeReadout()
        // Both accessories were added after the window applied its titlebar state, so they have to be
        // brought into line with it now: an accessory that appears afterwards would sit in the bar on
        // its own, and with the auto-hide bar away that means floating over the picture.
        (window as? ViewerWindow)?.refreshTrafficLights()
        window.setFrame(contentRect, display: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Pixel size in the titlebar

    /// The picture's pixel size, in the titlebar's trailing corner — a native accessory, so it lives in
    /// the bar the system draws rather than on a surface of our own. Empty while nothing is on screen.
    private func installSizeReadout() {
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sizeLabel.setFrameSize(NSSize(width: 120, height: 16))

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = sizeLabel
        window?.addTitlebarAccessoryViewController(accessory)
        sizeAccessory = accessory
        (window as? ViewerWindow)?.viewerAccessories.append(accessory)
    }

    /// Called by the viewer whenever the picture changes.
    fileprivate func updateSizeReadout(_ text: String) {
        sizeLabel.stringValue = text
        sizeLabel.isHidden = text.isEmpty
    }

    /// What the bar says, for tests.
    var sizeReadoutTextForTesting: String { sizeLabel.stringValue }

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
        // Registered with the window so it can be taken out of the titlebar when the bar is away
        // and put back when the bar appears: a titlebar accessory's `isHidden` does not take its
        // view out of a `.fullSizeContentView` window, which left the button floating over the
        // content (and, once the lights were revealed, on top of them).
        (window as? ViewerWindow)?.viewerAccessories.append(accessory)
        updateDrawerButton(open: viewerViewController.isDrawerOpen)
        // The accessory was added after the window applied its titlebar state, so it has to be
        // brought into line with it now: an accessory that appears after the bar has hidden would
        // otherwise sit over the image on its own.
        (window as? ViewerWindow)?.refreshTrafficLights()
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
        // Mode-aware: the browser's left column is the folder tree, the image mode's is the
        // thumbnail drawer. Driving the drawer unconditionally left the button doing nothing
        // visible while the browser was up.
        viewerViewController.toggleLeftColumn()
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
        // The viewer's repeating chrome tick belongs to the window it was started for.
        viewerViewController.stopChromeTimer()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        rememberContentSize()
        // The system has handed the top strip back: re-apply the user's titlebar mode and state.
        viewerViewController.windowTitlebarContextChanged()
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        viewerViewController.windowTitlebarContextChanged()
    }

    public func windowDidResize(_ notification: Notification) {
        rememberContentSize()
        // AppKit re-lays out the titlebar on a resize, which can bring the controls back.
        viewerViewController.windowTitlebarContextChanged()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        viewerViewController.windowTitlebarContextChanged()
    }

    public func windowDidResignKey(_ notification: Notification) {
        viewerViewController.windowTitlebarContextChanged()
    }

    /// A window drag must not hide the bar the user is dragging by. `windowWillMove` is the start;
    /// the end is the last `windowDidMove`, and a run loop turn after it the block is lifted.
    public func windowWillMove(_ notification: Notification) {
        viewerViewController.setTitlebarBlocked(.windowDrag, true)
    }

    public func windowDidMove(_ notification: Notification) {
        viewerViewController.titlebarDragDidContinue()
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        viewerViewController.refreshTitlebarBlocks()
    }
}
