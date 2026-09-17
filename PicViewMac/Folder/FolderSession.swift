import Foundation

/// Ordered view over the current folder plus the user's position in it.
/// Folder order and decode state stay separate: a rescan may change indices
/// without changing the current file's identity.
@MainActor
public final class FolderSession {
    public private(set) var items: [FolderItem] = []
    public private(set) var currentIndex: Int?
    public private(set) var directory: URL?

    public var onItemsChanged: (() -> Void)?
    public var onCurrentChanged: (() -> Void)?

    public init(items: [FolderItem] = [], directory: URL? = nil) {
        self.items = items
        self.directory = directory
        self.currentIndex = items.isEmpty ? nil : 0
    }

    public var currentItem: FolderItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Position of the current file inside the folder, for `index / total` chrome.
    public var positionDescription: String {
        guard let currentIndex, !items.isEmpty else { return "— / \(items.count)" }
        return "\(currentIndex + 1) / \(items.count)"
    }

    public func setItems(_ newItems: [FolderItem], preferredIdentity: FileIdentity? = nil) {
        let identity = preferredIdentity ?? currentItem?.id
        items = newItems
        if let identity, let index = newItems.firstIndex(where: { $0.id == identity }) {
            currentIndex = index
        } else if let identity, let index = newItems.firstIndex(where: { $0.id.refersToSameFile(as: identity) }) {
            currentIndex = index
        } else if let identity, let index = newItems.firstIndex(where: {
            // The same folder cannot hold two files with one name, so a filename
            // match survives path spelling differences such as `/var` versus
            // `/private/var` after a rescan.
            $0.displayName == identity.lastPathComponent
        }) {
            currentIndex = index
        } else if newItems.isEmpty {
            currentIndex = nil
        } else if let currentIndex {
            self.currentIndex = min(currentIndex, newItems.count - 1)
        } else {
            currentIndex = 0
        }
        onItemsChanged?()
        onCurrentChanged?()
    }

    @discardableResult
    public func select(index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        guard index != currentIndex else { return true }
        currentIndex = index
        onCurrentChanged?()
        return true
    }

    /// Selects a file by URL. Path spellings differ in practice (`/tmp` versus
    /// `/private/tmp`, symlinked folders), so an exact match is tried first and a
    /// filename match within this folder second.
    @discardableResult
    public func select(url: URL) -> Bool {
        if let index = items.firstIndex(where: { $0.url == url }) {
            return select(index: index)
        }
        if let index = items.firstIndex(where: { $0.url.path == url.standardizedFileURL.path }) {
            return select(index: index)
        }
        if let index = items.firstIndex(where: { $0.displayName == url.lastPathComponent }) {
            return select(index: index)
        }
        return false
    }

    @discardableResult
    public func select(identity: FileIdentity) -> Bool {
        guard let index = items.firstIndex(where: { $0.id.refersToSameFile(as: identity) }) else { return false }
        return select(index: index)
    }

    @discardableResult
    public func goNext() -> FolderItem? {
        guard let currentIndex else { return nil }
        return select(index: min(currentIndex + 1, items.count - 1)) ? currentItem : nil
    }

    @discardableResult
    public func goPrevious() -> FolderItem? {
        guard let currentIndex else { return nil }
        return select(index: max(currentIndex - 1, 0)) ? currentItem : nil
    }

    @discardableResult
    public func goFirst() -> FolderItem? {
        select(index: 0) ? currentItem : nil
    }

    @discardableResult
    public func goLast() -> FolderItem? {
        guard !items.isEmpty else { return nil }
        return select(index: items.count - 1) ? currentItem : nil
    }

    /// Recomputes the list, keeping the current file by identity where possible.
    public func rescanPreservingCurrent(using scanner: FolderScanner = FolderScanner()) async {
        guard let directory else { return }
        let identity = currentItem?.id
        guard let scanned = try? await scanner.scan(directory: directory) else { return }
        setItems(scanned, preferredIdentity: identity)
    }

    public func setDirectory(_ url: URL) {
        directory = url
    }

    /// Smart selection used after a delete or an externally removed file:
    /// prefer the item that took the removed slot, else the previous one.
    public func removeCurrentWithSmartSelection(identity: FileIdentity? = nil) {
        let target = identity ?? currentItem?.id
        guard let target, let index = items.firstIndex(where: { $0.id == target }) else { return }
        items.remove(at: index)
        if items.isEmpty {
            currentIndex = nil
        } else {
            currentIndex = min(index, items.count - 1)
        }
        onItemsChanged?()
        onCurrentChanged?()
    }

    /// Applies an external change (watcher-driven) without trashing anything.
    public func applyExternalRemoval(of identity: FileIdentity) {
        guard items.contains(where: { $0.id.refersToSameFile(as: identity) }) else { return }
        removeCurrentWithSmartSelection(identity: identity)
    }
}
