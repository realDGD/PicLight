import AppKit

/// The canvas's right-click menu, declared as data.
///
/// Declared rather than assembled in place for the same reason the dock's layout is: the order,
/// the grouping and the enablement are the contract, and a test can assert them without a live
/// menu. Every entry is either a `ViewerCommand` — which is what makes one implementation serve the
/// dock, the main menu and this menu — or one of the two actions that have no dock equivalent
/// (copy, and the folder browser, which the dock also gains).
@MainActor
public enum CanvasContextMenu {

    public enum Item: Equatable {
        /// An existing viewer command, handled by the viewer's single command path.
        case command(ViewerCommand)
        case separator
        /// Copy the image. A `ViewerCommand` too, so the same implementation serves the main menu.
        case copyImage
    }

    /// Availability, so the menu can grey out what cannot happen rather than offering a control
    /// that does nothing.
    public struct Availability: Equatable {
        public var hasImage: Bool
        public var canGoPrevious: Bool
        public var canGoNext: Bool
        public var hasMultiplePages: Bool

        public init(hasImage: Bool, canGoPrevious: Bool, canGoNext: Bool,
                    hasMultiplePages: Bool = false) {
            self.hasImage = hasImage
            self.canGoPrevious = canGoPrevious
            self.canGoNext = canGoNext
            self.hasMultiplePages = hasMultiplePages
        }
    }

    /// The menu, top to bottom: the clipboard, then the view, then moving through the folder, then
    /// the image's own orientation, then the chrome and information surfaces, and finally the
    /// destructive action on its own at the bottom.
    public static let items: [Item] = [
        .copyImage,
        .separator,
        .command(.zoomOut),
        .command(.zoomIn),
        .command(.zoomToFit),
        .command(.zoomToFitWidth),
        .command(.zoomActualPixels),
        .separator,
        .command(.previousImage),
        .command(.nextImage),
        .separator,
        .command(.rotateClockwise),
        .command(.rotateCounterClockwise),
        .command(.toggleMirror),
        .separator,
        .command(.browseFolder),
        .command(.toggleThumbnailDrawer),
        .command(.showImageInfo),
        .separator,
        .command(.moveToTrash),
    ]

    /// Whether an entry can be used with the state the viewer is in.
    public static func isEnabled(_ item: Item, _ availability: Availability) -> Bool {
        switch item {
        case .separator:
            return false
        case .copyImage:
            return availability.hasImage
        case let .command(command):
            switch command {
            case .zoomIn, .zoomOut, .zoomToFit, .zoomToFitWidth, .zoomActualPixels,
                 .rotateClockwise, .rotateCounterClockwise, .toggleMirror, .moveToTrash,
                 .showImageInfo, .browseFolder, .toggleThumbnailDrawer:
                return availability.hasImage
            case .previousImage, .firstImage:
                return availability.canGoPrevious
            case .nextImage, .lastImage:
                return availability.canGoNext
            case .nextPage:
                return availability.hasMultiplePages
            case .previousPage:
                return availability.hasMultiplePages
            default:
                return true
            }
        }
    }

    /// Builds the live menu. One target and one action for every command in it, so there is no
    /// second implementation of rotate, zoom or trash anywhere.
    public static func build(_ availability: Availability,
                             target: AnyObject,
                             commandAction: Selector,
                             copyAction: Selector) -> NSMenu {
        let menu = NSMenu(title: "图像")
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .copyImage:
                let entry = NSMenuItem(title: ViewerCommand.copyImage.localizedTitle,
                                       action: copyAction, keyEquivalent: "")
                entry.target = target
                entry.isEnabled = isEnabled(item, availability)
                entry.representedObject = ViewerCommand.copyImage.rawValue
                menu.addItem(entry)
            case let .command(command):
                let entry = NSMenuItem(title: command.localizedTitle,
                                       action: commandAction, keyEquivalent: "")
                entry.target = target
                entry.isEnabled = isEnabled(item, availability)
                entry.representedObject = command.rawValue
                menu.addItem(entry)
            }
        }
        return menu
    }

    /// The title to show for a command whose name depends on the state it will change, so a menu
    /// never says "show" for something already shown.
    public static func title(for command: ViewerCommand, drawerOpen: Bool,
                             infoVisible: Bool) -> String {
        switch command {
        case .toggleThumbnailDrawer: return drawerOpen ? "隐藏侧栏" : "显示侧栏"
        case .showImageInfo: return infoVisible ? "隐藏图像信息" : "显示图像信息"
        default: return command.localizedTitle
        }
    }
}
