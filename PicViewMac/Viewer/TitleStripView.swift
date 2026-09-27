import AppKit

/// The image mode's top strip: the file name, and the picture's pixel size on the right.
///
/// It replaces two things. The native titlebar was left transparent in the auto-hide mode, so the
/// system's own title text sat directly on the picture — white on a bright image, which is unreadable
/// (reported). And the bottom-left readout (`11 / 28 · 16% · 7586 × 1248`) appeared on a hover/idle
/// timer whose trigger nobody could predict; what it was actually consulted for was the size, which
/// belongs next to the name.
///
/// So: one glass surface, and specifically the *regular* glass variant the tool dock uses —
/// `MaterialHostView(style: .sidebar)` — rather than the clear variant the floating overlays take.
/// Measured complaint: with `.clear` the name and the size were still washed out over a bright picture,
/// because "clear" is glass with almost no tint behind the text. Our own labels use the dynamic label
/// colours on top of it, and a hairline under the strip separates it from the picture the way a
/// titlebar's separator does.
public final class TitleStripView: MaterialHostView {
    /// Where the strip's content starts: clear of the traffic lights (9…69 in window coordinates) and
    /// the left-column button beside them (78…108). The folder browser's merged toolbar uses the same
    /// inset for the same reason.
    public static let contentLeadingInset: CGFloat = 120
    /// What the strip covers when the window has no titlebar of its own (headless tests, full screen).
    public static let fallbackHeight: CGFloat = 28

    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    /// A titlebar has a hairline under it; without one the strip reads as text floating on the picture.
    private let separator = NSView()

    public override init(style: Style = .sidebar) {
        super.init(style: style)
        // Deliberately *not* overriding the material the way the drawer does: this style *is* the left
        // column's `.sidebar` material, and an override here would silently turn it back into a HUD.

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

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(sizeLabel)
        addSubview(separator)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                constant: Self.contentLeadingInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor,
                                                 constant: -12),

            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / (NSScreen.main?.backingScaleFactor ?? 2)),
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
    /// The hairline, for tests.
    var separatorForTesting: NSView { separator }
    var renderedSize: String { sizeLabel.stringValue }
}
