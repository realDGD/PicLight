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

/// Material host that adapts to the running OS instead of imitating newer looks.
public class MaterialHostView: NSVisualEffectView {
    public enum Style {
        case chrome
        case drawer
    }

    public init(style: Style) {
        super.init(frame: .zero)
        switch style {
        case .chrome:
            material = .hudWindow
            blendingMode = .withinWindow
        case .drawer:
            material = .sidebar
            blendingMode = .behindWindow
        }
        state = .followsWindowActiveState
        wantsLayer = true
        // Native system material only. macOS 26+ systems already render glass for
        // these materials, so nothing has to be imitated by hand.
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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

    public static var chromeAnimationDuration: TimeInterval {
        reduceMotion ? 0 : 0.15
    }

    public static var chromeFadeDuration: TimeInterval {
        reduceMotion ? 0 : 0.3
    }
}
