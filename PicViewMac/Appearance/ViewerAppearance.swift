import AppKit

public enum ViewerAppearanceMode: String, CaseIterable, Codable, Sendable {
    case system
    case black
    case darkGray
    case white
    case custom

    public var localizedName: String {
        switch self {
        case .system: return "跟随系统"
        case .black: return "黑色"
        case .darkGray: return "深灰"
        case .white: return "白色"
        case .custom: return "自定义"
        }
    }

    /// `nil` means "do not force `NSApp.appearance`".
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .black, .darkGray: return NSAppearance(named: .darkAqua)
        case .white: return NSAppearance(named: .aqua)
        case .custom: return nil
        }
    }

    public var canvasBackground: NSColor {
        switch self {
        case .system: return .clear
        case .black: return .black
        case .darkGray: return NSColor(white: 0.16, alpha: 1)
        case .white: return .white
        case .custom: return .clear
        }
    }
}

/// Hosts the native surface behind the auxiliary chrome: the hover bars, the
/// thumbnail drawer and the minimap. On macOS 26+ that surface is the system's
/// Liquid Glass (`NSGlassEffectView`); on macOS 14–15 it is a system
/// `NSVisualEffectView` material. Nothing is hand-drawn, and glass is never
/// placed over the image canvas for decoration.
public class MaterialHostView: NSView {
    public enum Style {
        /// Plain system material. Used for the viewer's own chrome (tool dock,
        /// info card, bottom bar) where readability matters more than effect.
        case hud
        /// Native glass on macOS 26+, a system material before that.
        case chrome
        case drawer
    }

    public let style: Style

    private var effectView: NSVisualEffectView?
    private var glassView: NSView?

    /// System material used on macOS 14–15. Where glass is available the system
    /// chooses its own material, so this is not applied there.
    public var material: NSVisualEffectView.Material = .hudWindow {
        didSet { effectView?.material = material }
    }

    public var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow {
        didSet { effectView?.blendingMode = blendingMode }
    }

    /// `true` when this surface is rendered with native Liquid Glass.
    public var usesNativeGlass: Bool { glassView != nil }

    /// `true` when a translucent material is actually installed for the current OS.
    public var usesSystemMaterial: Bool { effectView != nil }

    public init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true

        if #available(macOS 26.0, *), style != .hud {
            let glass = NSGlassEffectView()
            glass.style = style == .drawer ? .regular : .clear
            glass.cornerRadius = style == .drawer ? 0 : 10
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            glassView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = style == .drawer ? .sidebar : .hudWindow
            effect.blendingMode = style == .drawer ? .behindWindow : .withinWindow
            effect.state = .followsWindowActiveState
            effect.translatesAutoresizingMaskIntoConstraints = false
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            effect.layer?.masksToBounds = true
            addSubview(effect)
            NSLayoutConstraint.activate([
                effect.leadingAnchor.constraint(equalTo: leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: trailingAnchor),
                effect.topAnchor.constraint(equalTo: topAnchor),
                effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            effectView = effect
            material = effect.material
            blendingMode = effect.blendingMode
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The system accessibility switches are honored rather than fought.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateForAccessibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        updateForAccessibility()
    }

    /// With Reduce Transparency on, the translucent material is replaced by a
    /// solid surface instead of being forced back on the user.
    private func updateForAccessibility() {
        let reduce = !AccessibilityAppearance.surfaceIsTranslucent(
            reduceTransparency: AccessibilityAppearance.reduceTransparency)
        effectView?.isHidden = reduce
        glassView?.isHidden = reduce
        layer?.backgroundColor = reduce
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = reduce ? 10 : 0
    }
}

/// Respects the system accessibility switches instead of fighting them.
public enum AccessibilityAppearance {
    public static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Transitions collapse to instant when Reduce Motion is on. The decisions are
    /// pure so both branches can be verified without toggling system settings.
    public static func chromeAnimationDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.15
    }

    public static func chromeFadeDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.3
    }

    /// Whether a chrome surface may use a translucent material.
    public static func surfaceIsTranslucent(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }

    public static var chromeAnimationDuration: TimeInterval {
        chromeAnimationDuration(reduceMotion: reduceMotion)
    }

    public static var chromeFadeDuration: TimeInterval {
        chromeFadeDuration(reduceMotion: reduceMotion)
    }
}
