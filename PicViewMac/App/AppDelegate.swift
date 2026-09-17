import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.shared
    private var settingsWindowController: NSWindowController?
    private var isDefaultWindowPending = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Native window tabbing is disabled app-wide; the viewer never uses tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenuBuilder.build(appName: "PicViewMac", shortcutStore: environment.shortcuts)
        environment.fileOpener.openHandler = { [weak self] url, behavior in
            self?.environment.open(url: url, behavior: behavior)
        }
        NSApp.activate(ignoringOtherApps: false)

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

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock click: restore whatever is on screen, otherwise present a new viewer.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { _ = environment.presentNewViewerWindow() }
        return true
    }

    // MARK: - File open paths

    public func application(_ application: NSApplication, open urls: [URL]) {
        // A real open request supersedes the deferred default window.
        isDefaultWindowPending = false
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
