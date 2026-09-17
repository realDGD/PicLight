import Foundation

public enum ThumbnailFilenameMode: String, CaseIterable, Codable, Sendable {
    case never
    case always
    case hover

    public var localizedName: String {
        switch self {
        case .never: return "从不"
        case .always: return "始终"
        case .hover: return "悬停时"
        }
    }
}

public enum OpenBehavior: String, CaseIterable, Codable, Sendable {
    case newWindow
    case reuseCurrent

    public var localizedName: String {
        switch self {
        case .newWindow: return "新窗口"
        case .reuseCurrent: return "复用当前窗口"
        }
    }

    public var inverted: OpenBehavior { self == .newWindow ? .reuseCurrent : .newWindow }
}

public enum WindowSizingPolicy: String, CaseIterable, Codable, Sendable {
    case rememberLastSize
    case fitImageToScreen

    public var localizedName: String {
        switch self {
        case .rememberLastSize: return "记住上次窗口大小"
        case .fitImageToScreen: return "适应图像尺寸"
        }
    }
}

public enum DeleteFollowUp: String, CaseIterable, Codable, Sendable {
    case smart
    case stayInPlace

    public var localizedName: String {
        switch self {
        case .smart: return "智能选择下一张"
        case .stayInPlace: return "保持当前位置"
        }
    }
}

public enum BottomInfoField: String, CaseIterable, Codable, Sendable {
    case index
    case zoom
    case dimensions
    case fileSize
    case fileType
    case colorSpace

    public var localizedName: String {
        switch self {
        case .index: return "序号 / 总数"
        case .zoom: return "缩放"
        case .dimensions: return "像素尺寸"
        case .fileSize: return "文件大小"
        case .fileType: return "类型"
        case .colorSpace: return "色彩空间"
        }
    }
}

public enum AnimationLoopPreference: String, CaseIterable, Codable, Sendable {
    case followSource
    case once
    case infinite

    public var localizedName: String {
        switch self {
        case .followSource: return "跟随源文件"
        case .once: return "播放一次"
        case .infinite: return "无限循环"
        }
    }
}

/// Typed settings model backed by `UserDefaults`. Defaults match the spec table.
@MainActor
public final class AppSettings {
    public static let shared = AppSettings()

    public static let didChangeNotification = Notification.Name("com.picviewmac.settings.changed")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.thumbnailFilenames: ThumbnailFilenameMode.hover.rawValue,
            Key.sortKey: ImageSortKey.filename.rawValue,
            Key.sortDirection: SortDirection.ascending.rawValue,
            Key.openBehavior: OpenBehavior.newWindow.rawValue,
            Key.showTopFilename: true,
            Key.bottomFields: [BottomInfoField.index, .zoom, .dimensions]
                .map(\.rawValue),
            Key.windowSizing: WindowSizingPolicy.rememberLastSize.rawValue,
            Key.wheelMode: WheelMode.zoom.rawValue,
            Key.swipeMode: SwipeMode.smart.rawValue,
            Key.doubleClickMode: DoubleClickMode.fitDoubleFit.rawValue,
            Key.autoplayAnimations: true,
            Key.animationLoop: AnimationLoopPreference.followSource.rawValue,
            Key.deleteFollowUp: DeleteFollowUp.smart.rawValue,
            Key.appearance: ViewerAppearanceMode.system.rawValue,
            Key.immersive: false,
        ])
    }

    private enum Key {
        static let thumbnailFilenames = "thumbnailFilenames"
        static let sortKey = "sortKey"
        static let sortDirection = "sortDirection"
        static let openBehavior = "openBehavior"
        static let showTopFilename = "showTopFilename"
        static let bottomFields = "bottomFields"
        static let windowSizing = "windowSizing"
        static let lastWindowSize = "lastWindowSize"
        static let wheelMode = "wheelMode"
        static let swipeMode = "swipeMode"
        static let doubleClickMode = "doubleClickMode"
        static let autoplayAnimations = "autoplayAnimations"
        static let animationLoop = "animationLoop"
        static let deleteFollowUp = "deleteFollowUp"
        static let appearance = "appearance"
        static let immersive = "immersive"
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - Thumbnails and sorting

    public var thumbnailFilenames: ThumbnailFilenameMode {
        get { ThumbnailFilenameMode(rawValue: defaults.string(forKey: Key.thumbnailFilenames) ?? "") ?? .hover }
        set { defaults.set(newValue.rawValue, forKey: Key.thumbnailFilenames); notify() }
    }

    public var sortKey: ImageSortKey {
        get { ImageSortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .filename }
        set { defaults.set(newValue.rawValue, forKey: Key.sortKey); notify() }
    }

    public var sortDirection: SortDirection {
        get { SortDirection(rawValue: defaults.string(forKey: Key.sortDirection) ?? "") ?? .ascending }
        set { defaults.set(newValue.rawValue, forKey: Key.sortDirection); notify() }
    }

    // MARK: - Opening and windows

    public var openBehavior: OpenBehavior {
        get { OpenBehavior(rawValue: defaults.string(forKey: Key.openBehavior) ?? "") ?? .newWindow }
        set { defaults.set(newValue.rawValue, forKey: Key.openBehavior); notify() }
    }

    public var showTopFilename: Bool {
        get { defaults.bool(forKey: Key.showTopFilename) }
        set { defaults.set(newValue, forKey: Key.showTopFilename); notify() }
    }

    public var bottomFields: [BottomInfoField] {
        get {
            let raw = defaults.stringArray(forKey: Key.bottomFields) ?? []
            let fields = raw.compactMap(BottomInfoField.init(rawValue:))
            return fields.isEmpty ? [.index, .zoom, .dimensions] : fields
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: Key.bottomFields)
            notify()
        }
    }

    public var windowSizing: WindowSizingPolicy {
        get { WindowSizingPolicy(rawValue: defaults.string(forKey: Key.windowSizing) ?? "") ?? .rememberLastSize }
        set { defaults.set(newValue.rawValue, forKey: Key.windowSizing); notify() }
    }

    /// Persists the viewer content size only; never a transient full-screen frame.
    public var lastWindowSize: CGSize? {
        get {
            guard let raw = defaults.string(forKey: Key.lastWindowSize) else { return nil }
            let parts = raw.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            return CGSize(width: parts[0], height: parts[1])
        }
        set {
            guard let newValue else { defaults.removeObject(forKey: Key.lastWindowSize); return }
            defaults.set("\(Double(newValue.width))x\(Double(newValue.height))", forKey: Key.lastWindowSize)
        }
    }

    // MARK: - Interaction

    public var wheelMode: WheelMode {
        get { WheelMode(rawValue: defaults.string(forKey: Key.wheelMode) ?? "") ?? .zoom }
        set { defaults.set(newValue.rawValue, forKey: Key.wheelMode); notify() }
    }

    public var swipeMode: SwipeMode {
        get { SwipeMode(rawValue: defaults.string(forKey: Key.swipeMode) ?? "") ?? .smart }
        set { defaults.set(newValue.rawValue, forKey: Key.swipeMode); notify() }
    }

    public var doubleClickMode: DoubleClickMode {
        get { DoubleClickMode(rawValue: defaults.string(forKey: Key.doubleClickMode) ?? "") ?? .fitDoubleFit }
        set { defaults.set(newValue.rawValue, forKey: Key.doubleClickMode); notify() }
    }

    // MARK: - Animation and deletion

    public var autoplayAnimations: Bool {
        get { defaults.bool(forKey: Key.autoplayAnimations) }
        set { defaults.set(newValue, forKey: Key.autoplayAnimations); notify() }
    }

    public var animationLoop: AnimationLoopPreference {
        get { AnimationLoopPreference(rawValue: defaults.string(forKey: Key.animationLoop) ?? "") ?? .followSource }
        set { defaults.set(newValue.rawValue, forKey: Key.animationLoop); notify() }
    }

    public var deleteFollowUp: DeleteFollowUp {
        get { DeleteFollowUp(rawValue: defaults.string(forKey: Key.deleteFollowUp) ?? "") ?? .smart }
        set { defaults.set(newValue.rawValue, forKey: Key.deleteFollowUp); notify() }
    }

    // MARK: - Appearance

    public var appearance: ViewerAppearanceMode {
        get { ViewerAppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance); notify() }
    }

    public var immersive: Bool {
        get { defaults.bool(forKey: Key.immersive) }
        set { defaults.set(newValue, forKey: Key.immersive); notify() }
    }
}
