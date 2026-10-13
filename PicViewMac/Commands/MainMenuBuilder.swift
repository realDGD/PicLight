import AppKit

/// Builds the main menu. Core macOS shortcuts stay fixed; viewer commands use
/// the customizable shortcut store.
@MainActor
public enum MainMenuBuilder {
    public static func build(appName: String, shortcutStore: ShortcutStore) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenu(appName: appName))
        mainMenu.addItem(fileMenu(shortcutStore: shortcutStore))
        mainMenu.addItem(viewMenu(shortcutStore: shortcutStore))
        mainMenu.addItem(windowMenu(shortcutStore: shortcutStore))
        return mainMenu
    }

    private static func applicationMenu(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)
        menu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private static func fileMenu(shortcutStore: ShortcutStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "文件")
        menu.addItem(withTitle: "打开…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(withTitle: "在新窗口中打开…", action: #selector(AppDelegate.openInNewWindow(_:)), keyEquivalent: "O")
        menu.addItem(withTitle: "选择文件夹…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, .copyFilePath, in: shortcutStore)
        add(menu, .revealInFinder, in: shortcutStore)
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(menu, .moveToTrash, in: shortcutStore)
        add(menu, .moveToTrashWithoutConfirmation, in: shortcutStore)
        item.submenu = menu
        return item
    }

    private static func viewMenu(shortcutStore: ShortcutStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "显示")
        // The zoom group in the order macOS apps use: the two steps, then the fitted views.
        add(menu, .zoomIn, in: shortcutStore)
        add(menu, .zoomOut, in: shortcutStore)
        menu.addItem(.separator())
        add(menu, .zoomToFit, in: shortcutStore)
        add(menu, .zoomToFitWidth, in: shortcutStore)
        add(menu, .zoomActualPixels, in: shortcutStore)
        add(menu, .zoomDoubleFit, in: shortcutStore)
        menu.addItem(.separator())
        add(menu, .rotateClockwise, in: shortcutStore)
        add(menu, .rotateCounterClockwise, in: shortcutStore)
        add(menu, .toggleMirror, in: shortcutStore)
        menu.addItem(.separator())
        add(menu, .nextImage, in: shortcutStore)
        add(menu, .previousImage, in: shortcutStore)
        add(menu, .firstImage, in: shortcutStore)
        add(menu, .lastImage, in: shortcutStore)
        add(menu, .randomImage, in: shortcutStore)
        menu.addItem(.separator())
        add(menu, .nextPage, in: shortcutStore)
        add(menu, .previousPage, in: shortcutStore)
        add(menu, .togglePlayback, in: shortcutStore)
        menu.addItem(.separator())
        add(menu, .browseFolder, in: shortcutStore)
        add(menu, .toggleThumbnailDrawer, in: shortcutStore)
        add(menu, .toggleImmersive, in: shortcutStore)
        add(menu, .showImageInfo, in: shortcutStore)
        add(menu, .toggleSortDirection, in: shortcutStore)
        item.submenu = menu
        return item
    }

    private static func windowMenu(shortcutStore: ShortcutStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(menu, .toggleAlwaysOnTop, in: shortcutStore)
        menu.addItem(.separator())
        // Native full screen stays the standard macOS command.
        menu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    private static func add(_ menu: NSMenu, _ command: ViewerCommand, in store: ShortcutStore) {
        let item = NSMenuItem(title: command.localizedTitle,
                              action: #selector(AppDelegate.performViewerCommand(_:)),
                              keyEquivalent: "")
        if let shortcut = store.shortcut(for: command) {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers.eventFlags
        }
        item.representedObject = command.rawValue
        menu.addItem(item)
    }
}
