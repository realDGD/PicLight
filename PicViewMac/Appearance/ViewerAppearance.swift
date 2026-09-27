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
/// A surface cap: it covers the titlebar strip of a column that scrolls, and takes no events, so a
/// scroll or a click that starts in the strip goes to the list underneath it.
public final class SurfaceCapView: MaterialHostView {
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `NSVisualEffectView` material. Nothing is hand-drawn, and glass is never
/// placed over the image canvas for decoration.
public class MaterialHostView: NSView {
    public enum Style {
        /// Plain system material. Used for the viewer's own chrome (tool dock,
        /// info card, bottom bar) where readability matters more than effect.
        case hud
        /// Native glass on macOS 26+, a system material before that. `.dock` uses
        /// the regular glass variant, which reads better on a small floating pill
        /// than the clear variant.
        case chrome
        case drawer
        case dock
        /// The left column's surface: the system *sidebar* material, square, never glass.
        ///
        /// It is not glass, on any OS. The strip is the titlebar and it carries text that has to be
        /// read over whatever picture is behind it; glass — clear or regular — is a tint over the image,
        /// and the file name washed out (reported as "why does the dock read better than the titlebar",
        /// then "I want it like the left column's background"). `.sidebar` is the material the left
        /// column uses: more opaque, less of the picture through it, and it is what macOS itself gives a
        /// window's sidebar. Square, because the strip spans the window rather than floating in it.
        case sidebar
    }

    /// Whether this surface is drawn with the regular glass variant rather than the clear one.
    ///
    /// Only `.chrome` asks for clear: it is for the overlays that sit *on* a picture and should stay
    /// out of the way (the minimap). Everything that carries text worth reading — the dock, the
    /// drawer, the title strip — wants the regular variant's tint and blur.
    public var usesRegularGlass: Bool { style != .chrome }

    public private(set) var style: Style

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

    /// The corner radius applied to the system surface, for tests and for callers
    /// that reshape the container after construction.
    /// A cap that looks exactly like this surface, for covering the titlebar area of a column that
    /// scrolls under it.
    ///
    /// A column pinned to the window's edges has its content drawn under the traffic lights and the
    /// left-column button, because the window's content view spans the titlebar and the bar itself is
    /// transparent in this mode. The column's *background* belongs there; its scrolled rows do not. A
    /// cap of the same material, drawn above the scroll view, is what separates the two.
    public func makeSurfaceCap() -> MaterialHostView {
        let cap = SurfaceCapView(style: style)
        cap.material = material
        cap.blendingMode = blendingMode
        return cap
    }

    /// Whether this surface is drawn with the OS's own material rather than glass, and which material.
    /// The title strip is the case that matters: it must read like the left column, not like a tint over
    /// the picture.
    public var isSidebarMaterial: Bool {
        effectView?.material == .sidebar && effectView?.blendingMode == .withinWindow
    }

    public func setCornerRadius(_ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.cornerRadius = radius
        }
        effectView?.layer?.cornerRadius = radius
        layer?.cornerRadius = radius
    }

    public init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        buildSurface()
    }

    /// Swaps the surface under the content, keeping everything that sits on it. The labels and buttons
    /// of the dock are the host's own subviews, so they survive a change.
    public func setStyle(_ newStyle: Style) {
        guard newStyle != style else { return }
        style = newStyle
        glassView?.removeFromSuperview()
        effectView?.removeFromSuperview()
        glassView = nil
        effectView = nil
        buildSurface()
    }

    private func buildSurface() {

        // `.sidebar` deliberately stays on the system-material path even where glass exists: see the
        // style's own comment.
        if #available(macOS 26.0, *), style != .hud, style != .sidebar {
            let glass = NSGlassEffectView()
            glass.style = usesRegularGlass ? .regular : .clear
            let square = style == .drawer || style == .sidebar
            glass.cornerRadius = square ? 0 : 10
            glass.translatesAutoresizingMaskIntoConstraints = false
            // The bottom layer: a swap must not cover the content that is already on the surface.
            addSubview(glass, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            glassView = glass
        } else {
            let effect = NSVisualEffectView()
            // The strip takes the left column's material; the column itself blurs what is behind the
            // *window*, which is right for a column at the window's edge and wrong for a strip over the
            // picture the window is showing.
            let sidebarLike = style == .drawer || style == .sidebar
            effect.material = sidebarLike ? .sidebar : .hudWindow
            effect.blendingMode = style == .drawer ? .behindWindow : .withinWindow
            effect.state = .followsWindowActiveState
            effect.translatesAutoresizingMaskIntoConstraints = false
            addSubview(effect, positioned: .below, relativeTo: nil)
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            effect.layer?.masksToBounds = true
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
