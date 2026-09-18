import AppKit

/// The aspect-fit rect of an image inside a fixed slot.
///
/// A pure function, and the only place the thumbnail's drawn geometry is decided. It replaced an
/// Auto Layout `width == height × aspect` pair because the engine quantizes the solved dimension
/// to whole points: a 5:1 image in a 132 pt slot wants 26.4 pt of height and was laid out at 26,
/// which is a 1.5 % aspect error, and a 10:1 image came out at 10.15 rather than 10. Centring a
/// rect computed here is exact for every ratio and is directly assertable.
enum ThumbnailSlotGeometry {
    static func fittedRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect.isFinite, aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        let slotAspect = size.width / size.height
        // Which dimension the slot runs out of first. `>=` puts the square case on the
        // width-limited branch, where both give the same answer anyway.
        let widthLimited = aspect >= slotAspect
        let width = widthLimited ? size.width : size.height * aspect
        let height = widthLimited ? size.width / aspect : size.height
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}

/// The fixed square a thumbnail is presented in. Owns the image view and fits it on every layout.
///
/// The slot's own size is Auto Layout's business (it is a required 132×132); the image inside it
/// is not, because the fit has to be exact rather than quantized.
final class ThumbnailSlotView: NSView {
    let imageView = NSImageView()

    /// Source aspect, width ÷ height. Set by the cell.
    var imageAspect: CGFloat = 1 {
        didSet {
            guard imageAspect != oldValue else { return }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        imageView.frame = ThumbnailSlotGeometry.fittedRect(aspect: imageAspect, in: bounds.size)
    }
}

/// One drawer row: a fixed square thumbnail slot with the filename always under it.
/// Used as a reusable table cell so a folder with thousands of images never
/// materializes thousands of views at once.
///
/// The geometry is deliberately independent of the source image. The old cell sized the
/// image view *from* the image's aspect ratio, so the row's content moved with every
/// shape: a 10:1 strip was width-limited and sat pinned to the top of the cell, and the
/// selection card grew and shrank with the picture. Now the square slot is the fixed
/// frame and the image is fitted inside it, so a 10:1 and a 1:10 image occupy the same
/// 132×132 box, each centred, and the card never moves.
final class ThumbnailCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ThumbnailCellView")

    /// The square the thumbnail is presented in. Fixed: it is the cell's geometry.
    static let thumbnailSlotSize: CGFloat = 132
    /// The slot the filename occupies under the square. Fixed for the same reason.
    static let filenameSlotHeight: CGFloat = 18
    static let cardPadding: CGFloat = 8
    /// The selection card is padding + square + filename slot + padding. A constant, not a
    /// function of the image: this is what "the card does not resize" means.
    static var cardHeight: CGFloat { thumbnailSlotSize + 2 * cardPadding + filenameSlotHeight }
    static let rowHeight: CGFloat = 168
    /// The card is at least wide enough for the square plus its padding…
    static var cardMinimumWidth: CGFloat { thumbnailSlotSize + 2 * cardPadding }
    /// …grows with the drawer up to a point, so a long name has room…
    static let cardMaximumWidth: CGFloat = 200
    /// …and always leaves a gutter inside the drawer.
    static let cardHorizontalInset: CGFloat = 12
    /// The filename's own inset inside the card.
    static let filenameHorizontalInset: CGFloat = 6
    /// How much the current-item frame extends past the square on each side.
    static let selectionBorderHalo: CGFloat = 8

    private let nameLabel = NSTextField(labelWithString: "")
    private let selectionBackground = NSView()
    /// Drawn above the thumbnail so the current-item frame can never be covered by
    /// the image it frames.
    private let selectionBorder = PassthroughView()
    /// The fixed square the image is fitted into. A view of its own so the slot's size is a
    /// constraint in its own right and the image's aspect can only ever choose a rect inside it.
    private let thumbnailContainer = ThumbnailSlotView()
    private var imageView2: NSImageView { thumbnailContainer.imageView }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 8
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        // Middle truncation: the beginning and the extension are what identify a file whose
        // name is longer than the card.
        nameLabel.lineBreakMode = .byTruncatingMiddle
        // The label yields to the card's width limits so it truncates instead of pushing.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        selectionBorder.wantsLayer = true
        selectionBorder.layer?.borderWidth = 2
        selectionBorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionBorder.layer?.cornerRadius = 6
        selectionBorder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionBackground)
        addSubview(thumbnailContainer)
        addSubview(selectionBorder)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            // The card is the layout anchor and its height is a constant: it wraps the square
            // plus the filename slot, so neither the source aspect nor the filename's length can
            // change it.
            selectionBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionBackground.topAnchor.constraint(equalTo: topAnchor,
                                                     constant: Self.cardVerticalInset),
            selectionBackground.heightAnchor.constraint(equalToConstant: Self.cardHeight),
            selectionBackground.widthAnchor.constraint(greaterThanOrEqualToConstant:
                                                        Self.cardMinimumWidth),
            selectionBackground.widthAnchor.constraint(lessThanOrEqualToConstant:
                                                        Self.cardMaximumWidth),
            // A long filename must not stretch the card past the drawer either.
            selectionBackground.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor,
                                                       constant: -Self.cardHorizontalInset),

            thumbnailContainer.centerXAnchor.constraint(equalTo: selectionBackground.centerXAnchor),
            thumbnailContainer.topAnchor.constraint(equalTo: selectionBackground.topAnchor,
                                                    constant: Self.cardPadding),
            thumbnailContainer.widthAnchor.constraint(equalToConstant: Self.thumbnailSlotSize),
            thumbnailContainer.heightAnchor.constraint(equalToConstant: Self.thumbnailSlotSize),

            // The frame hugs the square, not the image: the square is what the cell offers, and a
            // frame that tracked the image would jump between rows of different shapes.
            selectionBorder.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            selectionBorder.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
            selectionBorder.widthAnchor.constraint(equalTo: thumbnailContainer.widthAnchor,
                                                  constant: Self.selectionBorderHalo),
            selectionBorder.heightAnchor.constraint(equalTo: thumbnailContainer.heightAnchor,
                                                   constant: Self.selectionBorderHalo),

            nameLabel.centerXAnchor.constraint(equalTo: selectionBackground.centerXAnchor),
            nameLabel.topAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: Self.filenameSlotHeight),
            nameLabel.leadingAnchor.constraint(equalTo: selectionBackground.leadingAnchor,
                                               constant: Self.filenameHorizontalInset),
            nameLabel.trailingAnchor.constraint(equalTo: selectionBackground.trailingAnchor,
                                                constant: -Self.filenameHorizontalInset),
        ])
        // The card grows to its maximum unless the drawer is narrower than that. A weak equality
        // pulling upwards, rather than a required one, so the two caps above stay satisfiable.
        let preferredWidth = selectionBackground.widthAnchor.constraint(
            equalToConstant: Self.cardMaximumWidth)
        preferredWidth.priority = NSLayoutConstraint.Priority(400)
        preferredWidth.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The slack left over once the card's fixed height is in the row. Half above, half below.
    static var cardVerticalInset: CGFloat { max(0, (rowHeight - cardHeight) / 2) }

    func configure(item: FolderItem, image: CGImage?, isCurrent: Bool) {
        nameLabel.stringValue = item.displayName
        setThumbnailImage(image)
        setCurrent(isCurrent)
    }

    func setThumbnail(_ image: CGImage) {
        setThumbnailImage(image)
    }

    private func setThumbnailImage(_ image: CGImage?) {
        imageView2.image = image.map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
        // A missing thumbnail is the full square rather than a shape of its own: the slot is
        // fixed, and inventing a placeholder aspect was what made rows of identical content
        // differ.
        thumbnailContainer.imageAspect = image.map(Self.aspect(of:)) ?? 1
    }

    private static func aspect(of image: CGImage) -> CGFloat {
        image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 1
    }

    func setCurrent(_ isCurrent: Bool) {
        selectionBackground.layer?.backgroundColor = isCurrent
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        selectionBackground.layer?.borderWidth = 0
        // The frame around the square is the visible selection cue, and it is the topmost layer
        // of the cell.
        selectionBorder.isHidden = !isCurrent
    }

    /// Exposed for tests: the current-item frame must outrank the thumbnail, and the square is
    /// what both the image and the frame are measured against.
    var selectionBorderView: NSView { selectionBorder }
    var thumbnailImageView: NSView { imageView2 }
    var selectionBackgroundView: NSView { selectionBackground }
    var thumbnailSlotView: NSView { thumbnailContainer }
    var nameLabelView: NSView { nameLabel }
}

/// A view that draws but never takes part in hit-testing, so an overlay frame
/// cannot swallow clicks meant for the cell underneath.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
