import AppKit

/// Selection is a draft. Only the explicit Apply button writes system defaults.
@MainActor
final class FileAssociationViewController: NSViewController {
    private let service: FileAssociationService
    private(set) var formatCheckboxes: [ImageFileFormat: NSButton] = [:]
    private(set) var statusLabels: [ImageFileFormat: NSTextField] = [:]
    let applyButton = NSButton(title: "设为默认打开应用", target: nil, action: nil)
    private let selectAllButton = NSButton(title: "全选", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新状态", target: nil, action: nil)
    private let feedback = NSTextView()

    init(service: FileAssociationService = FileAssociationService()) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 512, height: 480))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])

        let title = NSTextField(labelWithString: "图片格式关联")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)
        let intro = label("选择要关联的格式。设置后，双击这类图片将使用 PicLight 打开。")
        stack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let formats = NSStackView()
        formats.orientation = .vertical
        formats.alignment = .leading
        formats.spacing = 4
        stack.addArrangedSubview(formats)
        formats.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for format in ImageFileFormat.allCases {
            let checkbox = NSButton(checkboxWithTitle: format.displayName,
                                    target: self, action: #selector(selectionChanged))
            checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)
            checkbox.setAccessibilityLabel("关联 \(format.displayName)")
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11)
            status.alignment = .right
            status.lineBreakMode = .byTruncatingMiddle
            status.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let row = NSStackView(views: [checkbox, status])
            row.distribution = .fill
            row.spacing = 12
            formats.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: formats.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
            formatCheckboxes[format] = checkbox
            statusLabels[format] = status
        }

        selectAllButton.target = self
        selectAllButton.action = #selector(toggleSelectAll)
        refreshButton.target = self
        refreshButton.action = #selector(refreshStatus)
        stack.addArrangedSubview(NSStackView(views: [selectAllButton, refreshButton]))

        let hint = label("JPG/JPEG、TIF/TIFF 分别共用一项关联。取消勾选只改变本次选择，不会恢复之前的默认应用。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let feedbackScroll = NSScrollView()
        feedbackScroll.hasVerticalScroller = true
        feedbackScroll.drawsBackground = false
        feedback.isEditable = false
        feedback.isSelectable = true
        feedback.drawsBackground = false
        feedback.font = .systemFont(ofSize: 12)
        feedback.textContainerInset = .zero
        feedback.isVerticallyResizable = true
        feedback.isHorizontallyResizable = false
        feedback.autoresizingMask = [.width]
        feedback.textContainer?.widthTracksTextView = true
        feedbackScroll.documentView = feedback
        stack.addArrangedSubview(feedbackScroll)
        feedbackScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        feedbackScroll.heightAnchor.constraint(equalToConstant: 48).isActive = true
        feedback.setAccessibilityLabel("格式关联结果")
        feedback.string = service.canAssociate
            ? "点击“设为默认打开应用”应用所选格式；macOS 可能会要求确认。"
            : "请先将 PicLight.app 放到应用程序文件夹并启动，再设置格式关联。"

        applyButton.target = self
        applyButton.action = #selector(applyAssociations)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, applyButton])
        footer.spacing = 8
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = root
        refreshStatus()
    }

    private var selectedFormats: Set<ImageFileFormat> {
        Set(formatCheckboxes.compactMap { $0.value.state == .on ? $0.key : nil })
    }

    @objc private func selectionChanged() {
        applyButton.isEnabled = service.canAssociate && !service.isApplying && !selectedFormats.isEmpty
        selectAllButton.title = selectedFormats.count == ImageFileFormat.allCases.count ? "取消全选" : "全选"
    }

    @objc private func toggleSelectAll() {
        let state: NSControl.StateValue = selectedFormats.count == ImageFileFormat.allCases.count ? .off : .on
        formatCheckboxes.values.forEach { $0.state = state }
        selectionChanged()
    }

    @objc func refreshStatus() {
        for format in ImageFileFormat.allCases {
            let status = statusLabels[format]
            let current = service.currentApplication(for: format)
            if service.isAssociated(format) {
                status?.stringValue = "PicLight · 已关联"
                status?.textColor = .controlAccentColor
            } else {
                let name = current.map {
                    (FileManager.default.displayName(atPath: $0.path) as NSString).deletingPathExtension
                } ?? "未设置"
                status?.stringValue = "当前：\(name)"
                status?.textColor = .secondaryLabelColor
            }
            status?.toolTip = current?.path
        }
        selectionChanged()
    }

    @objc private func applyAssociations() {
        guard applyButton.isEnabled else { return }
        let selected = selectedFormats
        setControlsEnabled(false)
        feedback.string = "正在设置格式关联…请完成 macOS 显示的确认提示。"
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.associate(selected)
                feedback.textColor = result.failures.isEmpty ? .labelColor : .systemRed
                let summary = "已关联 \(result.associated.count) 种格式。"
                feedback.string = ([summary] + result.failures.map {
                    "\($0.format.rawValue.uppercased())：\($0.message)"
                }).joined(separator: "\n")
            } catch {
                feedback.textColor = .systemRed
                feedback.string = error.localizedDescription
            }
            setControlsEnabled(true)
            refreshStatus()
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        formatCheckboxes.values.forEach { $0.isEnabled = enabled }
        for button in [applyButton, selectAllButton, refreshButton] {
            button.isEnabled = enabled
        }
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 480
        return label
    }
}
