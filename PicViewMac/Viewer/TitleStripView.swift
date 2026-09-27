import AppKit

/// The image mode's top strip: the file name, and the picture's pixel size on the right.
///
/// It replaces two things. The native titlebar was left transparent in the auto-hide mode, so the
/// system's own title text sat directly on the picture — white on a bright image, which is unreadable
/// (reported). And the bottom-left readout (`11 / 28 · 16% · 7586 × 1248`) appeared on a hover/idle
/// timer whose trigger nobody could predict; what it was actually consulted for was the size, which
/// belongs next to the name.
///
/// So: one glass surface, like the tool dock — `MaterialHostView(style: .chrome)` is
/// `NSGlassEffectView` on macOS 26+ and the system material before it — with our own labels, which use
/// the dynamic label colours and stay readable over any picture.
public final class TitleStripView: MaterialHostView {
    /// Where the strip's content starts: clear of the traffic lights (9…69 in window coordinates) and
    /// the left-column button beside them (78…108). The folder browser's merged toolbar uses the same
    /// inset for the same reason.
    public static let contentLeadingInset: CGFloat = 120
    /// What the strip covers when the window has no titlebar of its own (headless tests, full screen).
    public static let fallbackHeight: CGFloat = 28

    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    public override init(style: Style = .chrome) {
        super.init(style: style)
        material = .hudWindow

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(sizeLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                constant: Self.contentLeadingInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor,
                                                 constant: -12),

            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// - Parameter pixelSize: the source's displayed size in pixels, or nil while nothing is on screen.
    public func update(title: String?, pixelSize: CGSize?) {
        titleLabel.stringValue = title ?? ""
        titleLabel.toolTip = title
        if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            sizeLabel.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        } else {
            sizeLabel.stringValue = ""
        }
    }

    /// Matches the strip to the window's titlebar, so the traffic lights and the left-column button sit
    /// on it rather than half above it. A height of 0 (a window without a titlebar) keeps the fallback.
    public func alignToTitlebar(height: CGFloat) {
        guard let constraint = heightConstraint else { return }
        constraint.constant = height > 0 ? height : Self.fallbackHeight
        needsLayout = true
    }

    /// The height constraint, so the owner can match it to the window.
    public func useHeightConstraint(_ constraint: NSLayoutConstraint) {
        heightConstraint = constraint
        constraint.constant = Self.fallbackHeight
    }

    private var heightConstraint: NSLayoutConstraint?

    /// What the strip says, for tests and for the acceptance runner: "what does the window call this
    /// picture, and how big is it" is a question about the view.
    var renderedTitle: String { titleLabel.stringValue }
    var renderedSize: String { sizeLabel.stringValue }
}
