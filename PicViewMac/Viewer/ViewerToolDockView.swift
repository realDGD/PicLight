import AppKit

/// The viewer's tool strip: a small floating panel at the bottom centre of the
/// image area, in the spirit of the Dock. It replaces the tools that used to live
/// in the hover top bar.
///
/// The dock auto-hides. It is on screen while the pointer is inside the invisible
/// strip along the bottom centre of the image area (see `revealZone(dockFrame:in:)`)
/// and while the user has pinned it open; otherwise it slides away after
/// `ToolDockVisibilityModel.timing.hideDelay`.
public final class ViewerToolDockView: MaterialHostView {
    public static let height: CGFloat = 38
    public static let bottomInset: CGFloat = 16
    /// Hover enlargement. Deliberately restrained: a hint of lift, not a fisheye.
    public static let hoveredScale: CGFloat = 1.12
    public static let neighbourScale: CGFloat = 1.04
    /// Press dip. Composed with the hover enlargement rather than replacing it.
    public static let pressedScale: CGFloat = 0.92

    /// Padding either side of the pill that still counts as "at the dock", so the
    /// strip can be hit without aiming at the buttons.
    public static let revealZoneTolerance: CGFloat = 24
    /// Extra band above the pill that still counts as "at the dock".
    public static let revealZoneMargin: CGFloat = 8
    /// How far the pill travels towards the bottom edge while it fades out.
    public static let hiddenSlideDistance: CGFloat = 8

    /// The pin, and the two states it renders.
    public static let pinSymbol = "pin.square"
    public static let pinnedSymbol = "pin.square.fill"
    public static let pinTooltip = "固定工具栏"
    public static let unpinTooltip = "取消固定工具栏"
    public static let pinnedTint: NSColor = .systemBlue

    public var onCommand: ((ViewerCommand) -> Void)?
    /// Fired when the user clicks the pin. The dock does not own the state: the
    /// viewer's visibility model does, so the pin, hover and immersive rules cannot
    /// disagree about whether the dock belongs on screen.
    public var onPinChanged: ((Bool) -> Void)?
    public private(set) var isPinned = false

    /// Layout: image adjustments and zoom on the left, the folder navigation pair in
    /// the middle, file and information actions on the right. `isGroupStart` draws a
    /// hairline separator before the entry.
    ///
    /// The pair is centred deliberately: four tools precede it and three follow, so it
    /// sits within half a slot of the dock's middle.
    static let toolDefinitions: [(symbol: String, command: ViewerCommand, tooltip: String,
                                  isGroupStart: Bool)] = [
        ("rotate.right", .rotateClockwise, "顺时针旋转", false),
        ("arrow.left.and.right.righttriangle.left.righttriangle.right", .toggleMirror, "水平镜像", false),
        ("arrow.down.left.and.arrow.up.right.rectangle", .zoomToFit, "适应窗口", false),
        ("arrow.left.and.right.square", .zoomToFitWidth, "适应宽度", false),
        ("arrow.left", .previousImage, "上一张", true),
        ("arrow.right", .nextImage, "下一张", false),
        ("1.square", .zoomActualPixels, "实际像素 100%", true),
        ("trash", .moveToTrash, "移到废纸篓", false),
        ("info.circle", .showImageInfo, "图像信息", false),
    ]

    private let stack = NSStackView()
    private let playbackButton = DockButton(symbol: "pause.fill", tooltip: "暂停 / 播放")
    private var toolButtons: [DockButton] = []
    /// The live `info.circle` button, so `isInfoVisible` reports the dock rather than
    /// a button that was never added to it.
    private var infoButton: DockButton?
    private let pinButton = DockButton(symbol: ViewerToolDockView.pinSymbol,
                                       tooltip: ViewerToolDockView.pinTooltip)

    public override init(style: Style = .dock) {
        super.init(style: style)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Self.height / 2
        layer?.masksToBounds = false
        // Match the glass pill to the dock's shape.
        setCornerRadius(Self.height / 2)

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for definition in Self.toolDefinitions {
            if definition.isGroupStart { stack.addArrangedSubview(Self.separator()) }
            let button = DockButton(symbol: definition.symbol, tooltip: definition.tooltip)
            button.onActivate = { [weak self] in self?.onCommand?(definition.command) }
            if definition.command == .showImageInfo { infoButton = button }
            toolButtons.append(button)
            stack.addArrangedSubview(button)
        }

        playbackButton.setSymbol("pause.fill")
        playbackButton.isHidden = true
        playbackButton.onActivate = { [weak self] in self?.onCommand?(.togglePlayback) }
        stack.addArrangedSubview(playbackButton)

        // The pin is the last control and sits behind its own separator: it governs
        // the dock itself rather than the image, so it must not read as one more
        // image action.
        stack.addArrangedSubview(Self.separator())
        pinButton.onActivate = { [weak self] in self?.togglePinned() }
        stack.addArrangedSubview(pinButton)

        wireHoverNeighbours()

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Commands the dock exposes, for tests and for the acceptance runner.
    public var commands: [ViewerCommand] { Self.toolDefinitions.map(\.command) }

    /// A hairline between tool groups.
    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    public var isInfoVisible: Bool { infoButton?.isHidden == false }

    public func setAnimated(_ animated: Bool, isPlaying: Bool) {
        playbackButton.isHidden = !animated
        playbackButton.setSymbol(isPlaying ? "pause.fill" : "play.fill")
    }

    // MARK: - Pin

    /// Mirrors the viewer's pin state into the button. The dock never pins itself:
    /// `onPinChanged` reports the click and the viewer decides, so one model owns
    /// whether the dock is on screen.
    public func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        let reduceMotion = AccessibilityAppearance.reduceMotion
        pinButton.setSymbol(pinned ? Self.pinnedSymbol : Self.pinSymbol,
                            crossfade: Self.pinCrossfadeDuration(reduceMotion: reduceMotion))
        pinButton.tint = pinned ? Self.pinnedTint : .labelColor
        pinButton.toolTip = pinned ? Self.unpinTooltip : Self.pinTooltip
        pinButton.setAccessibilityLabel(pinButton.toolTip)
    }

    public func togglePinned() {
        setPinned(!isPinned)
        onPinChanged?(isPinned)
    }

    /// The pin button, for tests and the acceptance runner.
    var pinControl: DockButton { pinButton }

    /// Total controls in the strip, in layout order — the pin included.
    var allButtons: [DockButton] { toolButtons + [playbackButton, pinButton] }

    // MARK: - Geometry

    /// The invisible strip that reveals an unpinned dock, in the coordinate space of
    /// the view that hosts both the dock and the pointer (the viewer's root view).
    ///
    /// It covers the pill plus `tolerance` on either side, and runs from the bottom
    /// edge up to the pill's top plus `margin`, so the pointer can approach from
    /// below without ever touching the dock itself.
    public static func revealZone(dockFrame: CGRect, in bounds: CGRect,
                                  tolerance: CGFloat = ViewerToolDockView.revealZoneTolerance,
                                  margin: CGFloat = ViewerToolDockView.revealZoneMargin) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              dockFrame.width > 0, dockFrame.height > 0 else { return .null }
        let top = min(dockFrame.maxY + margin, bounds.maxY)
        return CGRect(x: dockFrame.minX - tolerance,
                      y: bounds.minY,
                      width: dockFrame.width + 2 * tolerance,
                      height: top - bounds.minY)
    }

    /// Moves the pill towards the bottom edge while it fades. A layer transform, so
    /// the dock's frame — and every layout measurement taken from it — is unchanged:
    /// the canvas geometry is identical whether the dock is on screen or not.
    func setSlideOffset(_ offset: CGFloat, duration: TimeInterval) {
        guard let layer else { return }
        let transform = CATransform3DMakeTranslation(0, -offset, 0)
        guard duration > 0 else {
            layer.transform = transform
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = transform
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = transform
        layer.add(animation, forKey: "dockSlide")
    }

    /// The slide currently applied, for tests.
    var slideOffset: CGFloat { layer?.transform.m42 ?? 0 }

    // MARK: - Animation parameters

    static func hoverDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : DockButton.hoverDuration
    }

    static func pressDuration(pressed: Bool, reduceMotion: Bool) -> TimeInterval {
        guard !reduceMotion else { return 0 }
        return pressed ? DockButton.pressDuration : DockButton.releaseDuration
    }

    static func pinCrossfadeDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.12
    }

    /// No slide at all under Reduce Motion: the dock fades in place, and the caller
    /// also drops the fade duration to zero.
    public static func hiddenOffset(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : hiddenSlideDistance
    }

    /// Enlarges the hovered button and lifts its immediate neighbours slightly,
    /// the way a Dock does. Collapses to no animation when Reduce Motion is on.
    private func wireHoverNeighbours() {
        let all = allButtons
        for (index, button) in all.enumerated() {
            button.onHoverChanged = { (hovering: Bool) in
                let reduceMotion = AccessibilityAppearance.reduceMotion
                let duration = Self.hoverDuration(reduceMotion: reduceMotion)
                for (otherIndex, other) in all.enumerated() {
                    let scale: CGFloat
                    if other === button {
                        scale = hovering ? Self.hoveredScale : 1
                    } else if hovering, abs(otherIndex - index) == 1 {
                        scale = Self.neighbourScale
                    } else {
                        scale = 1
                    }
                    other.setHoverScale(scale, duration: duration)
                }
            }
        }
    }
}

/// One dock button.
///
/// Enlargement and the press dip are layer transforms around the button's own
/// centre, so layout never reflows: no frame, position or anchor point moves, and
/// the canvas keeps exactly the geometry it had while the dock was off screen.
final class DockButton: NSButton {
    static let hoverDuration: TimeInterval = 0.12
    /// How long the press dip takes, and how long it takes to come back.
    static let pressDuration: TimeInterval = 0.06
    static let releaseDuration: TimeInterval = 0.12
    static let pressedScale: CGFloat = 0.92
    /// Key handed to `add(_:forKey:)`. CoreAnimation files the transition under its own
    /// key, so lookups go through `symbolCrossfade` instead.
    static let symbolCrossfadeKey = "dockSymbolCrossfade"

    var onActivate: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    /// The hover component of the scale, set by the dock's neighbour logic.
    private(set) var hoverScale: CGFloat = 1
    private(set) var isPressed = false

    /// The scale actually applied: the hover enlargement composed with the press
    /// dip. A product rather than a replacement, so pressing while hovered keeps the
    /// enlargement and releasing restores exactly the hover scale.
    var effectiveScale: CGFloat { hoverScale * (isPressed ? Self.pressedScale : 1) }

    /// The icon tint. Defaults to the adaptive label colour so the icon follows the
    /// surface behind it; the pin swaps in the accent while it is engaged.
    var tint: NSColor = .labelColor {
        didSet { applyIconTint() }
    }

    init(symbol: String, tooltip: String) {
        super.init(frame: .zero)
        configure(tooltip: tooltip)
        setSymbol(symbol)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(tooltip: String) {
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        target = self
        action = #selector(activate)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /// Icons are template images and are tinted with a dynamic system colour, so
    /// they follow the surface behind them (light/dark, and the vibrancy of the
    /// glass) instead of being baked to one shade.
    ///
    /// `crossfade` swaps the glyph with a fade instead of a hard cut, which is what
    /// makes the pin's two states read as one control changing rather than two
    /// controls swapping places.
    /// The symbol currently installed. `NSImage.name` is empty for a system symbol, so the
    /// name is recorded here instead.
    private(set) var symbolName: String?

    func setSymbol(_ symbol: String, crossfade: TimeInterval = 0) {
        symbolName = symbol
        if crossfade > 0, let layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = crossfade
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: Self.symbolCrossfadeKey)
        }
        let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        symbolImage?.isTemplate = true
        image = symbolImage
        applyIconTint()
    }

    func applyIconTint() {
        contentTintColor = tint
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyIconTint()
    }

    /// The tint actually in force, for tests.
    var iconTint: NSColor? { contentTintColor }

    /// The crossfade still on the layer, for tests.
    ///
    /// CoreAnimation files a `CATransition` under its own key ("transition") rather than the
    /// one passed to `add(_:forKey:)`, so the lookup goes by class instead of by name.
    var symbolCrossfade: CATransition? {
        guard let layer else { return nil }
        for key in layer.animationKeys() ?? [] {
            if let transition = layer.animation(forKey: key) as? CATransition { return transition }
        }
        return nil
    }

    var symbolCrossfadeIsRunning: Bool { symbolCrossfade != nil }

    /// Sets the hover component and animates the composed scale.
    func setHoverScale(_ scale: CGFloat, duration: TimeInterval) {
        hoverScale = scale
        applyScale(duration: duration)
    }

    /// The hover component under its original name, kept for existing call sites.
    func setScale(_ scale: CGFloat, duration: TimeInterval) {
        setHoverScale(scale, duration: duration)
    }

    /// Presses or releases the dip. The durations live here so Reduce Motion can
    /// collapse them to zero in one place.
    func setPressed(_ pressed: Bool, reduceMotion: Bool = AccessibilityAppearance.reduceMotion) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        applyScale(duration: ViewerToolDockView.pressDuration(pressed: pressed,
                                                             reduceMotion: reduceMotion))
    }

    /// Enlarges the button about its own centre.
    ///
    /// The scaling is expressed as a transform around the middle of the layer's
    /// bounds rather than by moving the layer's anchor point: AppKit computes a
    /// layer's position from the anchor point, so changing the anchor point after
    /// layout shifts the button by half its size - which is what made the icons
    /// appear to jump downwards the first time the pointer entered the dock.
    private func applyScale(duration: TimeInterval) {
        guard let layer else { return }
        let bounds = layer.bounds
        let scale = effectiveScale
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, bounds.width / 2, bounds.height / 2, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -bounds.width / 2, -bounds.height / 2, 0)

        guard duration > 0 else {
            layer.transform = transform
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = transform
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = transform
        layer.add(animation, forKey: "hoverScale")
    }

    /// The layer transform currently applied, for tests that check the enlargement
    /// happens about the button's centre.
    var layerTransform: CATransform3D? { layer?.transform }
    var layerAnchorPoint: CGPoint? { layer?.anchorPoint }

    /// The rendered icon, exposed so tests can prove the button is actually
    /// visible rather than merely present.
    var symbolImage: NSImage? { image }

    /// Current enlargement, for tests.
    var currentScale: CGFloat {
        guard let layer else { return 1 }
        return layer.transform.m11
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
        // The tracking loop inside `super` consumes the mouse-up, so the release is
        // restored here rather than relying on `mouseUp(with:)` alone.
        super.mouseDown(with: event)
        setPressed(false)
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        super.mouseUp(with: event)
    }

    @objc private func activate() { onActivate?() }
}
