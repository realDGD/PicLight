import AppKit

/// One drawer row: a large aspect-preserved thumbnail plus an optional filename.
/// Used as a reusable table cell so a folder with thousands of images never
/// materializes thousands of views at once.
final class ThumbnailCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ThumbnailCellView")
    static let thumbnailHeight: CGFloat = 132
    static let rowHeight: CGFloat = 168

    private let imageView2 = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let selectionBackground = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    var filenameMode: ThumbnailFilenameMode = .hover {
        didSet { updateFilenameVisibility() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 8
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        imageView2.imageScaling = .scaleProportionallyUpOrDown
        imageView2.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionBackground)
        addSubview(imageView2)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            selectionBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            selectionBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            selectionBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            selectionBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            imageView2.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView2.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView2.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            imageView2.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -20),

            nameLabel.topAnchor.constraint(equalTo: imageView2.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(item: FolderItem, image: CGImage?, isCurrent: Bool,
                   filenameMode: ThumbnailFilenameMode) {
        self.filenameMode = filenameMode
        nameLabel.stringValue = item.displayName
        imageView2.image = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        setCurrent(isCurrent)
        updateFilenameVisibility()
    }

    func setThumbnail(_ image: CGImage) {
        imageView2.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func setCurrent(_ isCurrent: Bool) {
        selectionBackground.layer?.backgroundColor = isCurrent
            ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
            : NSColor.clear.cgColor
        selectionBackground.layer?.borderWidth = isCurrent ? 1 : 0
        selectionBackground.layer?.borderColor = NSColor.controlAccentColor.cgColor
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

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateFilenameVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateFilenameVisibility()
    }

    private func updateFilenameVisibility() {
        switch filenameMode {
        case .never: nameLabel.isHidden = true
        case .always: nameLabel.isHidden = false
        case .hover: nameLabel.isHidden = !isHovering
        }
    }
}
