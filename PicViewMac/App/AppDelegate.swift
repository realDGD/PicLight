import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let environment = AppEnvironment.shared
    private var settingsWindowController: NSWindowController?
    private var folderAccessWindowController: FolderAccessWindowController?
    private var isDefaultWindowPending = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Opt-in gesture diagnostics, first thing: every line after this one is trustworthy.
        GestureTrace.start()
        // Native window tabbing is disabled app-wide; the viewer never uses tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        Task { await environment.folderAccess.refresh() }
        rebuildMainMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMainMenu),
                                               name: ShortcutStore.didChangeNotification, object: nil)
        environment.fileOpener.openHandler = { [weak self] url, behavior in
            self?.environment.open(url: url, behavior: behavior)
        }
        // Deliberately activates. A window that is not yet key draws its Liquid Glass in the inactive
        // style — flatter, and much closer to the plain material — and the dock then "lights up" a
        // moment later when the window becomes key (reported as a dock that was frosted glass and
        // then switched). Activation is what the user asked for by opening a file, and on macOS 14+
        // `activate()` is the cooperative form of it.
        NSApp.activate()

        if let path = SelfTest.requestedFilePath {
            // No window is created here on purpose: the runner opens the file
            // through the same production path Finder uses, so the window it
            // checks is the one a real file open produces.
            SelfTest.run(fileURL: URL(fileURLWithPath: path), environment: environment)
            return
        }

        // Finder/open -a delivers files through application(_:open:) right after
        // launch. The default empty window is deferred by one run-loop pass so
        // opening a file does not leave a stray empty window behind.
        if !environment.hasVisibleViewer {
            isDefaultWindowPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isDefaultWindowPending else { return }
                self.isDefaultWindowPending = false
                if !self.environment.hasVisibleViewer {
                    _ = self.environment.presentNewViewerWindow()
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        environment.settings.quitAfterLastWindowClosed
    }

    @objc private func rebuildMainMenu() {
        NSApp.mainMenu = MainMenuBuilder.build(appName: "PicLight", shortcutStore: environment.shortcuts)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performViewerCommand(_:)),
              let raw = menuItem.representedObject as? String,
              let command = ViewerCommand(rawValue: raw) else { return true }
        guard let viewer = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentViewController as? ViewerViewController else {
            return false
        }
        if let editor = viewer.view.window?.firstResponder as? NSTextView, editor.isEditable { return false }
        if command == .toggleAlwaysOnTop {
            menuItem.state = viewer.view.window?.level == .floating ? .on : .off
        }
        return viewer.isCommandAvailable(command)
    }

    @objc public func openFolder(_ sender: Any?) {
        let targetController = (NSApp.keyWindow?.windowController as? ViewerWindowController)
            ?? (NSApp.mainWindow?.windowController as? ViewerWindowController)
            ?? environment.mostRecentViewer
        FolderAccessPanel.choose(store: environment.folderAccess, for: targetController?.window) { [weak self] url in
            guard let self else { return }
            let controller = targetController ?? self.environment.newViewerWindow()
            controller.viewerViewController.openFolder(url)
            controller.viewerViewController.enterFolderBrowser()
            controller.present()
        }
    }

    @objc func showFolderAccess(_ sender: Any?) {
        if folderAccessWindowController == nil { folderAccessWindowController = FolderAccessWindowController(store: environment.folderAccess) }
        folderAccessWindowController?.showWindow(nil)
        folderAccessWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openAuthorizedFolder(_ sender: NSURL) {
        let controller = (NSApp.mainWindow?.windowController as? ViewerWindowController)
            ?? environment.mostRecentViewer ?? environment.newViewerWindow()
        controller.viewerViewController.openFolder(sender as URL)
        controller.viewerViewController.enterFolderBrowser()
        controller.present()
    }

    public func applicationWillTerminate(_ notification: Notification) { environment.folderAccess.shutdown() }

    /// Dock click: restore whatever is on screen, otherwise present a new viewer.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { _ = environment.presentNewViewerWindow() }
        return true
    }

    // MARK: - File open paths

    public func application(_ application: NSApplication, open urls: [URL]) {
        // A real open request supersedes the deferred default window.
        isDefaultWindowPending = false
        // Same reason as at launch: an open from Finder has to bring the window forward, or the
        // chrome appears in the inactive material and changes under the user's eyes.
        NSApp.activate()
        environment.fileOpener.open(urls: urls)
    }

    @objc public func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SupportedImageTypes.requiredContentTypes
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            // The explicit "open in new window" command inverts the configured default.
            let inverted = self.isShiftHeld ? AppSettings.shared.openBehavior.inverted : nil
            self.environment.fileOpener.open(urls: panel.urls, behavior: inverted)
        }
    }

    @objc public func openInNewWindow(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SupportedImageTypes.requiredContentTypes
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.environment.fileOpener.open(urls: panel.urls, behavior: .newWindow)
        }
    }

    @objc public func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            settingsWindowController = controller
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc public func moveToTrash(_ sender: Any?) {
        currentViewer?.perform(.moveToTrash)
    }

    @objc public func performViewerCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = ViewerCommand(rawValue: raw) else { return }
        currentViewer?.perform(command)
    }

    private var currentViewer: ViewerViewController? {
        let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow
        if let controller = keyWindow?.contentViewController as? ViewerViewController {
            return controller
        }
        return environment.mostRecentViewer?.viewerViewController
    }

    private var isShiftHeld: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }
}
