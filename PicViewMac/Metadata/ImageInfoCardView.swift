import AppKit

/// Read-only image information, shown as an overlay card inside the viewer
/// window rather than in a separate window.
final class ImageInfoCardView: MaterialHostView {
    static let maximumWidth: CGFloat = 320
    static let maximumHeightFraction: CGFloat = 0.62

    private let titleLabel = NSTextField(labelWithString: "图像信息")
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let closeButton = NSButton()

    var onClose: (() -> Void)?

    private var metadata: ImageMetadata?
    private var descriptor: ImageDescriptor?

    override init(style: Style = .hud) {
        super.init(style: style)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.toolTip = "关闭图像信息"
        closeButton.setAccessibilityLabel("关闭图像信息")
        closeButton.target = self
        closeButton.action = #selector(requestClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        addSubview(titleLabel)
        addSubview(closeButton)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: Self.maximumWidth),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func requestClose() { onClose?() }

    /// Rebuilds the card for the supplied image. Called on every image change, so
    /// the card never shows stale information.
    func update(metadata: ImageMetadata?, descriptor: ImageDescriptor?) {
        self.metadata = metadata
        self.descriptor = descriptor
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let metadata else {
            stack.addArrangedSubview(row(key: "文件", value: "—"))
            return
        }
        for (key, value) in Self.rows(metadata: metadata, descriptor: descriptor) {
            stack.addArrangedSubview(row(key: key, value: value))
        }
    }

    /// Field list, shared with tests so the shown set is verifiable.
    static func rows(metadata: ImageMetadata,
                     descriptor: ImageDescriptor?) -> [(String, String)] {
        var rows: [(String, String)] = [("文件", metadata.fileName)]
        if let descriptor {
            rows.append(("显示尺寸",
                         "\(Int(descriptor.displayPixelSize.width)) × \(Int(descriptor.displayPixelSize.height))"))
            rows.append(("原始尺寸",
                         "\(Int(descriptor.pixelSize.width)) × \(Int(descriptor.pixelSize.height))"))
            if descriptor.pageCount > 1 { rows.append(("页数", "\(descriptor.pageCount)")) }
            if descriptor.animated {
                rows.append(("帧数", "\(descriptor.frameCount)"))
                let loop = descriptor.loopCount.map { $0 == 0 ? "无限" : "\($0)" } ?? "播放一次"
                rows.append(("循环", loop))
            }
        }
        // Orientation is reported as stored in the file; display already honors it.
        if let orientation = metadata.fields["方向"] { rows.append(("EXIF 方向", orientation)) }
        for key in metadata.fields.keys.sorted() where key != "方向" {
            rows.append((key, metadata.fields[key] ?? ""))
        }
        if let value = metadata.cameraMake { rows.append(("相机品牌", value)) }
        if let value = metadata.cameraModel { rows.append(("相机型号", value)) }
        if let value = metadata.lensModel { rows.append(("镜头", value)) }
        if let value = metadata.captureDate { rows.append(("拍摄时间", value)) }
        return rows
    }

    /// Number of rows currently shown, for tests.
    var rowCount: Int { stack.arrangedSubviews.count }
    var shownFile: String? { metadata?.fileName }

    private func row(key: String, value: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .right
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 11.5)
        valueLabel.isSelectable = true          // metadata values can be copied
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [keyLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}
