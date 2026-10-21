import AppKit

/// One set of metrics for every pane, so the window reads as a single form:
/// a top strip of icon tabs, then a right-aligned label column with the
/// controls in one column beside it.
///
/// The reference software's settings window (new_feature/功能清单与实现难度.md,
/// screenshots S01–S09) is the model: labels right-aligned in a fixed column,
/// a rounded card behind the viewer sub-tabs, and short panes that do not
/// stretch their rows to fill the window.
enum SettingsMetrics {
    static let windowWidth: CGFloat = 560
    /// Insets below the native preference toolbar.
    static let paneInset: CGFloat = 20
    /// Width of the right-aligned label column, measured from the pane inset.
    static let labelColumnWidth: CGFloat = 140
    static let generalLabelColumnWidth: CGFloat = 190
    static let labelSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 6
    static let groupSpacing: CGFloat = 26
    /// A pane never shrinks below this, so a two-row pane still looks like a window.
    static let minPaneHeight: CGFloat = 340
    static let minViewerPaneHeight: CGFloat = 590
    static let cardCornerRadius: CGFloat = 8
    static let cardInset: CGFloat = 20
    /// Top inset of a viewer sub-pane inside the card: clear of the segmented
    /// control that sits on the card's top edge.
    static let cardTopInset: CGFloat = 32
    /// Side inset of a viewer sub-pane inside the card.
    static let cardSideInset: CGFloat = 12
    static let subTabHeight: CGFloat = 24
    static let subTabWidth: CGFloat = 292
    /// Reference S02–S07 leaves a gap below the toolbar before the category bar.
    static let viewerTopInset: CGFloat = 20

    /// Width the controls have beside the label column. A viewer sub-pane sits
    /// inside the card, so it has less room than a top-level pane.
    static func controlColumnWidth(inCard: Bool) -> CGFloat {
        let paneWidth = windowWidth - 2 * paneInset - (inCard ? 2 * cardSideInset : 0)
        return paneWidth - (inCard ? labelColumnWidth : generalLabelColumnWidth) - labelSpacing
    }
}

// MARK: - Card and form

/// Rounded card behind the viewer sub-tabs, matching the reference window's
/// boxed page area.
@MainActor
final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsMetrics.cardCornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        // Inherit the window's actual, desktop-tinted background instead of
        // placing a separately resolved neutral gray panel over it.
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// Plain native buttons over one static surface. The text never participates in
/// a glass control's press/hover deformation, and there is only one outer border.
@MainActor
final class SettingsCategoryBar: NSView {
    let buttons: [NSButton]
    var onSelection: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet {
            for (index, button) in buttons.enumerated() {
                button.state = index == selectedIndex ? .on : .off
            }
            needsDisplay = true
        }
    }

    init(titles: [String]) {
        buttons = titles.map { NSButton(title: $0, target: nil, action: nil) }
        super.init(frame: NSRect(x: 0, y: 0, width: SettingsMetrics.subTabWidth,
                                height: SettingsMetrics.subTabHeight))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("看图分类")
        for (index, button) in buttons.enumerated() {
            button.setButtonType(.onOff)
            button.isBordered = false
            button.font = .systemFont(ofSize: 13)
            button.tag = index
            button.target = self
            button.action = #selector(selectCategory(_:))
            button.state = index == selectedIndex ? .on : .off
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(titles[index])
            if let cell = button.cell as? NSButtonCell {
                cell.highlightsBy = []
                cell.showsStateBy = []
            }
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let segmentWidth = (bounds.width - 4) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 2 + CGFloat(index) * segmentWidth, y: 2,
                                  width: segmentWidth, height: bounds.height - 4)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlColor.withAlphaComponent(0.08).setFill()
        border.fill()
        NSColor.separatorColor.setStroke()
        border.lineWidth = 1
        border.stroke()
        guard buttons.indices.contains(selectedIndex) else { return }
        let selected = NSBezierPath(roundedRect: buttons[selectedIndex].frame, xRadius: 5, yRadius: 5)
        NSColor.controlColor.withAlphaComponent(0.18).setFill()
        selected.fill()
        for index in 1..<buttons.count where index != selectedIndex && index != selectedIndex + 1 {
            let line = NSBezierPath()
            let x = buttons[index].frame.minX
            line.move(to: NSPoint(x: x, y: 6))
            line.line(to: NSPoint(x: x, y: bounds.height - 6))
            line.lineWidth = 1
            NSColor.separatorColor.setStroke()
            line.stroke()
        }
    }

    @objc private func selectCategory(_ sender: NSButton) {
        selectedIndex = sender.tag
        onSelection?(selectedIndex)
    }
}

/// Builds the label-column-plus-control rows that every pane shares.
///
/// A group title sits in the label column of the group's first row, exactly as
/// the reference window does; later rows in the group leave the column empty so
/// their controls stay in one column.
@MainActor
final class SettingsForm {
    let stack = NSStackView()
    /// Width the controls have beside the label column. Notes wrap to it, so a
    /// pane inside the card must not wrap to a top-level pane's width.
    let controlColumnWidth: CGFloat
    let labelColumnWidth: CGFloat
    private var pendingGroup: String?
    private var hasGroup = false
    private var groupRows: [NSView] = []

    init(controlColumnWidth: CGFloat = SettingsMetrics.controlColumnWidth(inCard: false),
         labelColumnWidth: CGFloat = SettingsMetrics.generalLabelColumnWidth) {
        self.controlColumnWidth = controlColumnWidth
        self.labelColumnWidth = labelColumnWidth
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Height the rows need at their current width.
    var fittingHeight: CGFloat {
        stack.layoutSubtreeIfNeeded()
        return stack.fittingSize.height
    }

    /// Starts a group. The next row's empty label becomes this title; when the
    /// next row brings its own label, both share that first row.
    func group(_ title: String) {
        if let last = groupRows.last { stack.setCustomSpacing(SettingsMetrics.groupSpacing, after: last) }
        pendingGroup = title
    }

    /// Adds a row. A `nil` label means "nothing in the label column", which is
    /// how checkbox rows and follow-up rows line up with the controls above.
    @discardableResult
    func row(_ label: String?, control: NSView, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSView {
        let group = pendingGroup
        if group != nil { hasGroup = true; pendingGroup = nil }
        if let label, hasGroup {
            // A group's heading and first setting share a line, as in S03. Follow-up
            // checkbox rows start at the group's control column, not after this caption.
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 12)
            let pair = NSStackView(views: [caption, control])
            pair.spacing = 8
            pair.alignment = alignment
            return appendRow(group ?? "", control: pair, alignment: alignment)
        }
        return appendRow(group ?? label ?? "", control: control, alignment: alignment)
    }

    /// A note under the controls, indented to the control column.
    @discardableResult
    func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = controlColumnWidth
        return row(nil, control: label, alignment: .top)
    }

    /// A note as wide as the pane, like the reference window's long footnotes.
    @discardableResult
    func fullWidthNote(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = labelColumnWidth
            + SettingsMetrics.labelSpacing + controlColumnWidth
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        groupRows.append(label)
        pendingGroup = nil
        return label
    }

    /// A control that spans the pane, like the reference window's shortcut table.
    @discardableResult
    func fullWidthControl(_ control: NSView) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(control)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        groupRows.append(control)
        pendingGroup = nil
        return control
    }

    @discardableResult
    private func appendRow(_ label: String, control: NSView,
                           alignment: NSLayoutConstraint.Attribute = .centerY) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = alignment
        row.spacing = SettingsMetrics.labelSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        groupRows.append(row)
        return row
    }
}

/// A pane: the form rows plus the inset around them, and the height they need.
@MainActor
final class SettingsPaneView: NSView {
    let form: SettingsForm
    private let insets: NSEdgeInsets

    init(insets: NSEdgeInsets = NSEdgeInsets(top: SettingsMetrics.paneInset,
                                             left: SettingsMetrics.paneInset,
                                             bottom: SettingsMetrics.paneInset,
                                             right: SettingsMetrics.paneInset),
         controlColumnWidth: CGFloat = SettingsMetrics.controlColumnWidth(inCard: false),
         labelColumnWidth: CGFloat = SettingsMetrics.generalLabelColumnWidth) {
        self.insets = insets
        self.form = SettingsForm(controlColumnWidth: controlColumnWidth, labelColumnWidth: labelColumnWidth)
        let layoutWidth = controlColumnWidth + labelColumnWidth + SettingsMetrics.labelSpacing + insets.left + insets.right
        super.init(frame: NSRect(x: 0, y: 0, width: layoutWidth, height: SettingsMetrics.minPaneHeight))
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(form.stack)
        NSLayoutConstraint.activate([
            form.stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            form.stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            form.stack.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            form.stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The height this pane wants in the window.
    var contentHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return form.fittingHeight + insets.top + insets.bottom
    }
}
