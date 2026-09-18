import AppKit

/// One drawer row: a large aspect-preserved thumbnail plus an optional filename.
/// Used as a reusable table cell so a folder with thousands of images never
/// materializes thousands of views at once.
final class ThumbnailCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ThumbnailCellView")
    static let thumbnailHeight: CGFloat = 132
    /// The slot the filename occupies inside the selection card. Fixed, so showing or hiding the
    /// filename on hover cannot make the card jump.
    static let filenameSlotHeight: CGFloat = 18
    static let cardPadding: CGFloat = 8
    static let rowHeight: CGFloat = 168

    private let imageView2 = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let selectionBackground = NSView()
    /// Drawn above the thumbnail so the current-item frame can never be covered by
    /// the image it frames.
    private let selectionBorder = PassthroughView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    /// The image box aspect. Installed for both the placeholder and a real thumbnail: the width must
    /// never depend on whether an image happens to be set, which is what let the box collapse to
    /// zero width (and the current-item frame to 8 pt) before the asynchronous thumbnail arrived.
    private var imageAspectConstraint: NSLayoutConstraint?
    /// Aspect of the empty box, chosen to fill the default drawer width rather than to match any
    /// particular shape.
    private static let placeholderAspect: CGFloat = 1.45

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

        selectionBorder.wantsLayer = true
        selectionBorder.layer?.borderWidth = 2
        selectionBorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionBorder.layer?.cornerRadius = 6
        selectionBorder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionBackground)
        addSubview(imageView2)
        addSubview(selectionBorder)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            // The selection card wraps the thumbnail and the filename slot, not the whole row. The
            // row is 168 pt tall by design, so binding the card to the cell painted the selection
            // colour over a large empty band under a wide image.
            // Centred on the image and at least as wide as it, but never *pushing* it: an equality
            // on both edges would fight the image's aspect constraint, and a minimum width alone
            // would have to break the aspect to be satisfied (measured: a 2:3 thumbnail came out
            // 0.79 instead of 0.67). The card takes a lower bound from the image instead.
            selectionBackground.centerXAnchor.constraint(equalTo: imageView2.centerXAnchor),
            selectionBackground.widthAnchor.constraint(greaterThanOrEqualTo: imageView2.widthAnchor,
                                                       constant: 2 * Self.cardPadding),
            selectionBackground.topAnchor.constraint(equalTo: imageView2.topAnchor,
                                                     constant: -Self.cardPadding),
            selectionBackground.bottomAnchor.constraint(equalTo: imageView2.bottomAnchor,
                                                        constant: Self.cardPadding
                                                            + Self.filenameSlotHeight),

            imageView2.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView2.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView2.heightAnchor.constraint(lessThanOrEqualToConstant: Self.thumbnailHeight),
            imageView2.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -20),

            selectionBorder.centerXAnchor.constraint(equalTo: imageView2.centerXAnchor),
            selectionBorder.centerYAnchor.constraint(equalTo: imageView2.centerYAnchor),
            selectionBorder.widthAnchor.constraint(equalTo: imageView2.widthAnchor, constant: 8),
            selectionBorder.heightAnchor.constraint(equalTo: imageView2.heightAnchor, constant: 8),

            nameLabel.topAnchor.constraint(equalTo: imageView2.bottomAnchor, constant: 4),
            // Bound to the card, not to the cell: a portrait thumbnail's card is narrow, and a label
            // spanning the whole row would hang outside the selection colour.
            nameLabel.leadingAnchor.constraint(equalTo: selectionBackground.leadingAnchor,
                                               constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: selectionBackground.trailingAnchor,
                                                constant: -6),
            // And the card keeps a usable filename width even for an ultra-tall image, instead of
            // collapsing to a sliver around it.
            selectionBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        // The box wants to be as large as the two caps allow; the aspect constraint below decides
        // how the size is split between width and height. The priority has to beat NSImageView's own
        // content-size hugging (250): at equal priority the engine satisfied the hug and the empty
        // box measured 0 pt wide, which is the collapsed frame the user saw.
        let fill = imageView2.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight)
        fill.priority = NSLayoutConstraint.Priority(500)
        fill.isActive = true
        setThumbnailAspect(Self.placeholderAspect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(item: FolderItem, image: CGImage?, isCurrent: Bool,
                   filenameMode: ThumbnailFilenameMode) {
        self.filenameMode = filenameMode
        nameLabel.stringValue = item.displayName
        imageView2.image = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        setThumbnailAspect(image.map(Self.aspect(of:)) ?? Self.placeholderAspect)
        setCurrent(isCurrent)
        updateFilenameVisibility()
    }

    func setThumbnail(_ image: CGImage) {
        imageView2.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        setThumbnailAspect(Self.aspect(of: image))
    }

    private static func aspect(of image: CGImage) -> CGFloat {
        image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : placeholderAspect
    }

    /// The one constraint that makes the box size unique: width == height × aspect. With the two
    /// required caps (height ≤ 132, width ≤ cell − 20) and the weak fill above, the solver has
    /// exactly one answer for any aspect — wide images are limited by the width, tall ones by the
    /// height — and it never falls back on NSImageView's intrinsic size.
    private func setThumbnailAspect(_ aspect: CGFloat) {
        imageAspectConstraint?.isActive = false
        let constraint = imageView2.widthAnchor.constraint(equalTo: imageView2.heightAnchor,
                                                          multiplier: max(0.01, aspect))
        constraint.priority = NSLayoutConstraint.Priority(999)
        constraint.isActive = true
        imageAspectConstraint = constraint
        needsLayout = true
    }

    func setCurrent(_ isCurrent: Bool) {
        selectionBackground.layer?.backgroundColor = isCurrent
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        selectionBackground.layer?.borderWidth = 0
        // The frame around the image is the visible selection cue, and it is the
        // topmost layer of the cell.
        selectionBorder.isHidden = !isCurrent
    }

    /// Exposed for tests: the current-item frame must outrank the thumbnail.
    var selectionBorderView: NSView { selectionBorder }
    var thumbnailImageView: NSView { imageView2 }
    var selectionBackgroundView: NSView { selectionBackground }
    var nameLabelView: NSView { nameLabel }

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


/// A view that draws but never takes part in hit-testing, so an overlay frame
/// cannot swallow clicks meant for the cell underneath.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
