import AppKit

/// Bottom info bar. Field set is configurable; the default is
/// `index / total · zoom · pixel dimensions`.
public final class BottomInfoBarView: MaterialHostView {
    public static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")

    public override init(style: Style = .chrome) {
        super.init(style: style)
        material = .hudWindow
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(fields: [BottomInfoField], session: FolderSession,
                       descriptor: ImageDescriptor?, viewport: ViewportState,
                       metadata: ImageMetadata?, pageDescription: String?) {
        var parts: [String] = []
        for field in fields {
            switch field {
            case .index:
                parts.append(session.positionDescription)
            case .zoom:
                parts.append("\(viewport.zoomPercent)%")
            case .dimensions:
                let size = descriptor?.displayPixelSize
                parts.append(size.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "—")
            case .fileSize:
                parts.append(metadata?.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
            case .fileType:
                parts.append(descriptor?.typeIdentifier ?? "—")
            case .colorSpace:
                parts.append(metadata?.colorSpace ?? "—")
            }
        }
        // TIFF pages are shown separately so they are never confused with the
        // folder `index / total`.
        if let pageDescription, session.items.count > 0 {
            parts.append("页 \(pageDescription)")
        }
        label.stringValue = parts.joined(separator: "   ·   ")
    }

    /// The line as rendered, for tests and for the acceptance runner: "what does the readout
    /// actually say" is a question about the view, not about the inputs it was handed.
    var renderedText: String { label.stringValue }
}
