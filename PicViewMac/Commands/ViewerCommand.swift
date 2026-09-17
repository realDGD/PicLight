import AppKit

/// Every user-triggerable viewer action. Shortcuts are customizable for viewer
/// commands; the core macOS shortcuts stay fixed.
public enum ViewerCommand: String, CaseIterable, Codable, Sendable {
    case open
    case close
    case settings
    case nextImage
    case previousImage
    case firstImage
    case lastImage
    case zoomToFit
    case zoomToFitWidth
    case zoomActualPixels
    case zoomDoubleFit
    case rotateClockwise
    case rotateCounterClockwise
    case toggleMirror
    case moveToTrash
    case togglePlayback
    case nextPage
    case previousPage
    case toggleImmersive
    case toggleFullScreen
    case toggleThumbnailDrawer
    case showImageInfo
    case toggleSortDirection

    public var localizedTitle: String {
        switch self {
        case .open: return "打开…"
        case .close: return "关闭窗口"
        case .settings: return "设置…"
        case .nextImage: return "下一张图像"
        case .previousImage: return "上一张图像"
        case .firstImage: return "第一张图像"
        case .lastImage: return "最后一张图像"
        case .zoomToFit: return "适应窗口"
        case .zoomToFitWidth: return "适应宽度"
        case .zoomActualPixels: return "实际像素 100%"
        case .zoomDoubleFit: return "适应 ×2"
        case .rotateClockwise: return "顺时针旋转"
        case .rotateCounterClockwise: return "逆时针旋转"
        case .toggleMirror: return "水平镜像"
        case .moveToTrash: return "移到废纸篓"
        case .togglePlayback: return "暂停 / 播放"
        case .nextPage: return "下一页"
        case .previousPage: return "上一页"
        case .toggleImmersive: return "沉浸模式"
        case .toggleFullScreen: return "进入全屏幕"
        case .toggleThumbnailDrawer: return "缩略图抽屉"
        case .showImageInfo: return "图像信息"
        case .toggleSortDirection: return "切换排序方向"
        }
    }

    /// Commands that stay on the standard system shortcut and are not customizable.
    public var isFixedSystemShortcut: Bool {
        switch self {
        case .open, .close, .settings, .toggleFullScreen: return true
        default: return false
        }
    }
}

/// Where a command is handled. The router only forwards; folder state lives in
/// `FolderSession`, chrome state in the view controller.
@MainActor
public protocol ViewerCommandHandling: AnyObject {
    func perform(_ command: ViewerCommand)
}

@MainActor
public final class ViewerCommandRouter {
    public weak var handler: ViewerCommandHandling?

    public init(handler: ViewerCommandHandling? = nil) {
        self.handler = handler
    }

    public func perform(_ command: ViewerCommand) {
        handler?.perform(command)
    }
}
