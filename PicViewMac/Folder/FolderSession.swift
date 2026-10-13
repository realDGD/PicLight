import Foundation

/// What produced a publication.
///
/// The view layer needs this because "the user moved" and "the list moved under them" look identical
/// from a changed index: the first may move the viewport and reveal a tree row, the second must
/// leave both exactly where they were (measured: a lazy size fill pulled a scrolled-away grid back
/// to the selected row, and a rescan re-expanded a node the user had collapsed).
public enum FolderChangeReason: Sendable {
    /// An explicit move to another folder or file.
    case navigation
    /// The directory was re-read (watcher, manual refresh).
    case rescan
    /// The user changed the sort order.
    case sort
    /// The same list was republished with more information (lazy dimensions).
    case metadata
    /// The user selected another item in the same list.
    case selection
    /// Items were removed.
    case removal
    /// The bytes at a path changed.
    case sourceReplacement

    /// Whether a selection that arrives with this reason should be brought into sight.
    public var revealsSelection: Bool {
        switch self {
        case .navigation, .selection, .removal, .sort: return true
        case .rescan, .metadata, .sourceReplacement: return false
        }
    }
}

/// Ordered view over the current folder plus the user's position in it.
/// Folder order and decode state stay separate: a rescan may change indices
/// without changing the current file's identity.
@MainActor
public final class FolderSession {
    public private(set) var items: [FolderItem] = []
    public private(set) var currentIndex: Int?
    public private(set) var directory: URL?
    /// The reason behind the most recent publication. See `FolderChangeReason`.
    public private(set) var lastChangeReason: FolderChangeReason = .navigation

    public var onItemsChanged: (() -> Void)?
    public var onCurrentChanged: (() -> Void)?
    public var loopBrowsing = false {
        didSet { if oldValue != loopBrowsing { onItemsChanged?() } }
    }

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

    public var canGoPrevious: Bool {
        guard let currentIndex, items.count > 1 else { return false }
        return loopBrowsing || currentIndex > 0
    }

    public var canGoNext: Bool {
        guard let currentIndex, items.count > 1 else { return false }
        return loopBrowsing || currentIndex < items.count - 1
    }

    /// Position of the current file inside the folder, for `index / total` chrome.
    public var positionDescription: String {
        guard let currentIndex, !items.isEmpty else { return "— / \(items.count)" }
        return "\(currentIndex + 1) / \(items.count)"
    }

    public func setItems(_ newItems: [FolderItem], preferredIdentity: FileIdentity? = nil,
                         reason: FolderChangeReason = .rescan) {
        lastChangeReason = reason
        let identity = preferredIdentity ?? currentItem?.id
        let previousIndex = currentIndex
        let previousItem = currentItem?.id
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
        // Only a *moved position* is a selection change. `setItems` is also how the same list is
        // republished with more information (the lazy dimension fill) and how a re-sort reorders it
        // around the file the user is on. Firing the selection callback for those made the viewer
        // re-open the image, which resets a multi-page document to its first page and throws the
        // viewport away for a list that only gained metadata.
        if currentIndex != previousIndex || currentItem?.id != previousItem {
            onCurrentChanged?()
        }
    }

    /// Recomputes the list, holding the *slot* rather than the file. This is what
    /// "stay in place" means once a folder changes underneath the viewer: the user
    /// keeps their position in the list, even if a re-sort puts a different file
    /// there.
    public func setItems(_ newItems: [FolderItem], preferredIndex: Int?,
                         reason: FolderChangeReason = .rescan) {
        lastChangeReason = reason
        let previousIndex = currentIndex
        let previousItem = currentItem?.id
        items = newItems
        if let preferredIndex, !newItems.isEmpty {
            currentIndex = min(max(preferredIndex, 0), newItems.count - 1)
        } else if newItems.isEmpty {
            currentIndex = nil
        } else {
            currentIndex = min(currentIndex ?? 0, newItems.count - 1)
        }
        onItemsChanged?()
        if currentIndex != previousIndex || currentItem?.id != previousItem {
            onCurrentChanged?()
        }
    }

    /// Re-applies the *shared* sort order to the items.
    ///
    /// There is one sort order for the whole app — `AppSettings.sortKey` / `sortDirection` — and
    /// both modes read it. This exists so the gallery can ask for the list to be re-ordered after
    /// the user changes it, without the session holding a second copy of the preference.
    public func resortSharedOrder() {
        let settings = AppSettings.shared
        let sorted = ImageSort.sort(items, by: settings.sortKey, direction: settings.sortDirection)
        lastChangeReason = .sort
        guard sorted.map(\.id) != items.map(\.id) else { return }
        setItems(sorted, reason: .sort)
    }

    /// Replaces the list with the same files carrying more information, holding the current one.
    /// Used when a lazy probe (dimensions) fills something in: the user must not be moved by it.
    public func replaceItemsPreservingCurrent(_ newItems: [FolderItem],
                                              reason: FolderChangeReason = .metadata) {
        setItems(newItems, preferredIdentity: currentItem?.id, reason: reason)
    }

    @discardableResult
    public func select(index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        guard index != currentIndex else { return true }
        lastChangeReason = .selection
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
        let next = currentIndex + 1
        return select(index: next < items.count ? next : (loopBrowsing ? 0 : currentIndex)) ? currentItem : nil
    }

    @discardableResult
    public func goPrevious() -> FolderItem? {
        guard let currentIndex else { return nil }
        let previous = currentIndex - 1
        return select(index: previous >= 0 ? previous : (loopBrowsing ? items.count - 1 : currentIndex)) ? currentItem : nil
    }

    @discardableResult
    public func goRandom() -> FolderItem? {
        guard items.count > 1, let currentIndex else { return currentItem }
        let candidate = Int.random(in: 0..<(items.count - 1))
        let index = candidate >= currentIndex ? candidate + 1 : candidate
        return select(index: index) ? currentItem : nil
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
        lastChangeReason = .removal
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

    /// Deletes without moving the user: after removing the item at index N, the
    /// new item at index N is selected, or the new last item when N is past the
    /// end. This is the "stay in place" preference, and it is deliberately
    /// different from the smart policy, which prefers the next image by identity.
    public func removeCurrentKeepingPosition(identity: FileIdentity? = nil) {
        lastChangeReason = .removal
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
