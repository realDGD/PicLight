import AppKit

/// Read-only image information. Reachable from More in the top hover bar.
public final class ImageInfoViewController: NSViewController {
    private let stack = NSStackView()
    private let metadata: ImageMetadata
    private let descriptor: ImageDescriptor?

    public init(metadata: ImageMetadata, descriptor: ImageDescriptor?) {
        self.metadata = metadata
        self.descriptor = descriptor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 460))
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true

        for (key, value) in rows {
            stack.addArrangedSubview(row(key: key, value: value))
        }
        scroll.documentView = stack
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private var rows: [(String, String)] {
        var result: [(String, String)] = [("文件", metadata.fileName)]
        if let descriptor {
            result.append(("显示尺寸", "\(Int(descriptor.displayPixelSize.width)) × \(Int(descriptor.displayPixelSize.height))"))
            result.append(("原始尺寸", "\(Int(descriptor.pixelSize.width)) × \(Int(descriptor.pixelSize.height))"))
            if descriptor.pageCount > 1 { result.append(("页数", "\(descriptor.pageCount)")) }
            if descriptor.animated {
                result.append(("帧数", "\(descriptor.frameCount)"))
                let loop = descriptor.loopCount.map { $0 == 0 ? "无限" : "\($0)" } ?? "播放一次"
                result.append(("循环", loop))
            }
        }
        // Orientation is reported as stored in the file; display already honors it.
        if let orientation = metadata.fields["方向"] {
            result.append(("EXIF 方向", orientation))
        }
        for key in metadata.fields.keys.sorted() where key != "方向" {
            result.append((key, metadata.fields[key] ?? ""))
        }
        if let make = metadata.cameraMake { result.append(("相机品牌", make)) }
        if let model = metadata.cameraModel { result.append(("相机型号", model)) }
        if let lens = metadata.lensModel { result.append(("镜头", lens)) }
        if let date = metadata.captureDate { result.append(("拍摄时间", date)) }
        return result
    }

    private func row(key: String, value: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .right
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.isSelectable = true
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [keyLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }
}

/// Hosts the read-only info view in a real window, not an overlay panel.
@MainActor
public final class ImageInfoWindowController {
    private var window: NSWindow?

    public init() {}

    public func show(metadata: ImageMetadata, descriptor: ImageDescriptor?, relativeTo parent: NSWindow?) {
        let controller = ImageInfoViewController(metadata: metadata, descriptor: descriptor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "图像信息"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        if let parent {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.maxX - 400, y: parent.frame.maxY - 60))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
