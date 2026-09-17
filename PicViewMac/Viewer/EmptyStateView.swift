import AppKit

/// Present when there is no image to show: a bare launch, a folder that holds no
/// supported images, or a bounded decode still running (an oversized PNG takes
/// ~16 s, and saying "this folder has no supported images" during that window is
/// both wrong and alarming). It is a normal subview of the viewer window (never a
/// window of its own) and it steps out of hit-testing as soon as an image loads.
final class EmptyStateView: NSView {
    enum Reason: Equatable {
        /// Nothing has been opened yet.
        case noImageOpened
        /// A folder was opened but contains no supported images.
        case folderHasNoImages
        /// An image was found and its decode is still running (spec §12).
        case loading

        var title: String {
            switch self {
            case .noImageOpened: return "打开图片…"
            case .folderHasNoImages: return "此文件夹中没有支持的图像"
            case .loading: return "正在解码…"
            }
        }

        var hint: String {
            switch self {
            case .noImageOpened: return "拖放图片到这里，或按 ⌘O"
            case .folderHasNoImages: return "支持 BMP、GIF、ICO、PNG、JPEG、TIFF、WebP"
            case .loading: return "超大图片需要十几秒，完成后会自动显示"
            }
        }
    }

    /// Asks the app to run the normal Open command, so the empty state does not
    /// grow its own file-opening path.
    var onOpenRequested: (() -> Void)?
    /// Routed through the shared file-open coordinator, exactly like a Finder drop.
    var onFilesDropped: (([URL]) -> Void)?

    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let stack = NSStackView()
    private var isDragHighlighted = false

    private(set) var reason: Reason = .noImageOpened

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        symbolView.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                   accessibilityDescription: "图片")
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .thin)
        symbolView.contentTintColor = .tertiaryLabelColor
        symbolView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 20, weight: .light)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center

        openButton.title = "打开图片…"
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.target = self
        openButton.action = #selector(requestOpen)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [symbolView, titleLabel, openButton, hintLabel] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(18, after: titleLabel)
        stack.setCustomSpacing(16, after: openButton)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            symbolView.heightAnchor.constraint(equalToConstant: 52),
        ])

        registerForDraggedTypes([.fileURL])
        apply(reason: .noImageOpened)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(reason: Reason) {
        self.reason = reason
        titleLabel.stringValue = reason.title
        hintLabel.stringValue = reason.hint
        openButton.isHidden = reason != .noImageOpened
    }

    @objc private func requestOpen() {
        onOpenRequested?()
    }

    /// A drag highlight is drawn on the layer so the state reads clearly without
    /// adding another view above the canvas.
    private func setDragHighlighted(_ highlighted: Bool) {
        isDragHighlighted = highlighted
        layer?.borderWidth = highlighted ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 12
    }

    // MARK: - Drag and drop

    private func supportedURLs(in sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: options) as? [URL] ?? []
        return urls.filter { SupportedImageTypes.isCandidate($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !supportedURLs(in: sender).isEmpty else { return [] }
        setDragHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDragHighlighted(false)
        let urls = supportedURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}
