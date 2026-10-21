import AppKit

/// AppKit owns the icon/label tabs, selection, keyboard access and overflow.
@MainActor
final class SettingsToolbarController: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "PicLight.Settings")
    private weak var controller: SettingsViewController?
    private let identifiers = SettingsViewController.paneTitles.indices.map {
        NSToolbarItem.Identifier("PicLight.Settings.\($0)")
    }

    init(controller: SettingsViewController, window: NSWindow) {
        self.controller = controller
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        select(controller.selectedPaneTitle)
        controller.onSelectedPaneChange = { [weak self] title in self?.select(title) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + identifiers + [.flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = identifiers.firstIndex(of: identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = SettingsViewController.paneTitles[index]
        item.image = NSImage(systemSymbolName: SettingsViewController.tabSymbols[index],
                             accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(activate(_:))
        return item
    }

    private func select(_ title: String) {
        guard let index = SettingsViewController.paneTitles.firstIndex(of: title) else { return }
        toolbar.selectedItemIdentifier = identifiers[index]
    }
    @objc func activate(_ item: NSToolbarItem) {
        guard let index = identifiers.firstIndex(of: item.itemIdentifier) else { return }
        controller?.selectPane(SettingsViewController.paneTitles[index])
    }
}
