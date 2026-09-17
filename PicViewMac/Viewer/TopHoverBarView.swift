import AppKit

/// The top hover region: the real standard window buttons placed in the
/// full-size titlebar, a middle-truncated filename and the J2 tool controls.
/// The remaining strip stays a normal window drag surface.
public final class TopHoverBarView: MaterialHostView {
    public static let height: CGFloat = 44

    public var onCommand: ((ViewerCommand) -> Void)?

    private let filenameField = NSTextField(labelWithString: "")
    private let toolsStack = NSStackView()
    private let playbackButton = NSButton()
    private var standardButtons: [NSButton] = []

    public init() {
        super.init(style: .chrome)
        translatesAutoresizingMaskIntoConstraints = false

        filenameField.font = .systemFont(ofSize: 13, weight: .medium)
        filenameField.textColor = .labelColor
        filenameField.lineBreakMode = .byTruncatingMiddle
        filenameField.alignment = .center
        filenameField.translatesAutoresizingMaskIntoConstraints = false

        toolsStack.orientation = .horizontal
        toolsStack.spacing = 2
        toolsStack.translatesAutoresizingMaskIntoConstraints = false

        for (symbol, command, tooltip) in Self.toolDefinitions {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.toolTip = tooltip
            button.target = self
            button.action = #selector(handleToolButton(_:))
            button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            toolsStack.addArrangedSubview(button)
        }

        playbackButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停")
        playbackButton.imagePosition = .imageOnly
        playbackButton.isBordered = false
        playbackButton.toolTip = "暂停 / 播放"
        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback)
        playbackButton.isHidden = true
        toolsStack.addArrangedSubview(playbackButton)

        addSubview(filenameField)
        addSubview(toolsStack)

        NSLayoutConstraint.activate([
            filenameField.centerXAnchor.constraint(equalTo: centerXAnchor),
            filenameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            filenameField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 84),
            filenameField.trailingAnchor.constraint(lessThanOrEqualTo: toolsStack.leadingAnchor, constant: -8),

            toolsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            toolsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let toolDefinitions: [(String, ViewerCommand, String)] = [
        ("rotate.right", .rotateClockwise, "顺时针旋转"),
        ("arrow.left.and.right.righttriangle.left.righttriangle.right", .toggleMirror, "水平镜像"),
        ("arrow.up.left.and.arrow.down.right", .zoomToFit, "适应窗口"),
        ("1.square", .zoomActualPixels, "实际像素 100%"),
        ("trash", .moveToTrash, "移到废纸篓"),
        ("ellipsis.circle", .showImageInfo, "更多 / 图像信息"),
    ]

    /// Uses the window's real `standardWindowButton` controls; they are faded
    /// rather than replaced by custom circles.
    public func attachStandardButtons(from window: NSWindow) {
        standardButtons = [.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
    }

    public func setFilename(_ name: String?, visible: Bool) {
        filenameField.stringValue = name ?? ""
        filenameField.isHidden = !visible || name == nil
    }

    public func setAnimated(_ animated: Bool, isPlaying: Bool) {
        playbackButton.isHidden = !animated
        playbackButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: isPlaying ? "暂停" : "播放"
        )
    }

    @objc private func handleToolButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let command = ViewerCommand(rawValue: raw) else { return }
        onCommand?(command)
    }

    @objc private func togglePlayback() { onCommand?(.togglePlayback) }

    /// The strip is a drag surface except where a control consumes the event.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hitTest(point) === self {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}
