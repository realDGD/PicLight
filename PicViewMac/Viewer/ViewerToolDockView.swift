import AppKit

/// The viewer's tool strip: a small floating panel at the bottom centre of the
/// image area, in the spirit of the Dock. It replaces the tools that used to live
/// in the hover top bar.
public final class ViewerToolDockView: MaterialHostView {
    public static let height: CGFloat = 38
    public static let bottomInset: CGFloat = 16
    /// Hover enlargement. Deliberately restrained: a hint of lift, not a fisheye.
    public static let hoveredScale: CGFloat = 1.12
    public static let neighbourScale: CGFloat = 1.04

    public var onCommand: ((ViewerCommand) -> Void)?

    static let toolDefinitions: [(symbol: String, command: ViewerCommand, tooltip: String)] = [
        ("rotate.right", .rotateClockwise, "顺时针旋转"),
        ("arrow.left.and.right.righttriangle.left.righttriangle.right", .toggleMirror, "水平镜像"),
        ("arrow.up.left.and.arrow.down.right", .zoomToFit, "适应窗口"),
        ("1.square", .zoomActualPixels, "实际像素 100%"),
        ("trash", .moveToTrash, "移到废纸篓"),
        ("info.circle", .showImageInfo, "图像信息"),
    ]

    private let stack = NSStackView()
    private let playbackButton = DockButton(symbol: "pause.fill", command: .togglePlayback,
                                            tooltip: "暂停 / 播放")
    private var toolButtons: [DockButton] = []
    private let infoButton: DockButton

    public override init(style: Style = .dock) {
        let infoDefinition = Self.toolDefinitions.last!
        infoButton = DockButton(symbol: infoDefinition.symbol, command: infoDefinition.command,
                                tooltip: infoDefinition.tooltip)
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
            let button = DockButton(symbol: definition.symbol, command: definition.command,
                                    tooltip: definition.tooltip)
            toolButtons.append(button)
            stack.addArrangedSubview(button)
        }

        playbackButton.setSymbol("pause.fill")
        playbackButton.isHidden = true
        stack.addArrangedSubview(playbackButton)

        for button in toolButtons + [playbackButton] {
            button.onActivate = { [weak self] command in self?.onCommand?(command) }
        }
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

    public var isInfoVisible: Bool { !infoButton.isHidden }

    public func setAnimated(_ animated: Bool, isPlaying: Bool) {
        playbackButton.isHidden = !animated
        playbackButton.setSymbol(isPlaying ? "pause.fill" : "play.fill")
    }

    /// Enlarges the hovered button and lifts its immediate neighbours slightly,
    /// the way a Dock does. Collapses to no animation when Reduce Motion is on.
    private func wireHoverNeighbours() {
        let all = toolButtons + [playbackButton]
        for (index, button) in all.enumerated() {
            button.onHoverChanged = { [weak self] (hovering: Bool) in
                guard let self else { return }
                let reduceMotion = AccessibilityAppearance.reduceMotion
                let duration = reduceMotion ? 0 : 0.12
                for (otherIndex, other) in all.enumerated() {
                    let scale: CGFloat
                    if other === button {
                        scale = hovering ? Self.hoveredScale : 1
                    } else if hovering, abs(otherIndex - index) == 1 {
                        scale = Self.neighbourScale
                    } else {
                        scale = 1
                    }
                    other.setScale(scale, duration: duration)
                }
            }
        }
    }
}

/// One dock button. Enlargement is a layer transform so layout never reflows.
final class DockButton: NSButton {
    var onActivate: ((ViewerCommand) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let command: ViewerCommand
    private var trackingArea: NSTrackingArea?

    init(symbol: String, command: ViewerCommand, tooltip: String) {
        self.command = command
        super.init(frame: .zero)
        configure(command: command, tooltip: tooltip)
        setSymbol(symbol)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(command: ViewerCommand, tooltip: String) {
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
    func setSymbol(_ symbol: String) {
        let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        symbolImage?.isTemplate = true
        image = symbolImage
        applyIconTint()
    }

    func applyIconTint() {
        contentTintColor = .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyIconTint()
    }

    /// The tint actually in force, for tests.
    var iconTint: NSColor? { contentTintColor }

    func setScale(_ scale: CGFloat, duration: TimeInterval) {
        guard let layer else { return }
        // Keep the layer centred while scaling: AppKit anchors layers bottom-left.
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        let transform = CATransform3DMakeScale(scale, scale, 1)
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

    @objc private func activate() { onActivate?(command) }
}
