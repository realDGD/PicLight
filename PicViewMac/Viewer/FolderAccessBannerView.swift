import AppKit

/// A persistent recovery surface shared by image and grid modes; it reserves no canvas space.
@MainActor
final class FolderAccessBannerView: NSView {
    var onChoose: (() -> Void)?
    var onRetry: (() -> Void)?
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 10
        let choose = NSButton(title: "选择文件夹…", target: self, action: #selector(selectFolder))
        let retry = NSButton(title: "重试", target: self, action: #selector(retryFolder))
        choose.bezelStyle = .rounded; retry.bezelStyle = .rounded
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, choose, retry])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ failure: FolderReadFailure?) {
        label.stringValue = failure?.message ?? ""
        label.toolTip = failure?.directory.path
        isHidden = failure == nil
    }
    @objc private func selectFolder() { onChoose?() }
    @objc private func retryFolder() { onRetry?() }
}
