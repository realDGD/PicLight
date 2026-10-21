import Foundation

public struct FolderItem: Identifiable, Hashable, Sendable {
    public let id: FileIdentity
    public let url: URL
    public let displayName: String
    public let byteSize: Int64?
    public let creationDate: Date?
    public let modificationDate: Date?
    /// Filled lazily, only when dimension sorting is requested.
    public var pixelSize: CGSize?

    public init(url: URL, id: FileIdentity? = nil, byteSize: Int64? = nil,
                creationDate: Date? = nil, modificationDate: Date? = nil,
                pixelSize: CGSize? = nil) {
        self.url = url
        self.id = id ?? FileIdentity(url: url)
        self.displayName = url.lastPathComponent
        self.byteSize = byteSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelSize = pixelSize
    }

    public static func == (lhs: FolderItem, rhs: FolderItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum ImageSortKey: String, CaseIterable, Sendable, Codable {
    case filename
    case fileExtension
    case modificationDate
    case creationDate
    case fileSize
    case dimensions

    public var localizedName: String {
        switch self {
        case .filename: return "文件名"
        case .fileExtension: return "扩展名"
        case .modificationDate: return "修改时间"
        case .creationDate: return "创建时间"
        case .fileSize: return "文件大小"
        case .dimensions: return "图像尺寸"
        }
    }

    /// The file's extension, lower-cased, from the display name. Computed rather than stored: a
    /// sort key that needed a new field on `FolderItem` would have to be maintained by every scan.
    static func fileExtension(of item: FolderItem) -> String {
        (item.displayName as NSString).pathExtension.lowercased()
    }
}

public enum SortDirection: String, CaseIterable, Sendable, Codable {
    case ascending
    case descending

    public var localizedName: String { self == .ascending ? "升序" : "降序" }
}

public enum ImageSort {
    /// Natural comparison so `2.jpg` precedes `10.jpg`, with the URL as a stable
    /// tie-breaker for equal keys.
    public static func sort(_ items: [FolderItem], by key: ImageSortKey,
                            direction: SortDirection = .ascending) -> [FolderItem] {
        let sorted = items.sorted { lhs, rhs in
            let order = compare(lhs, rhs, key: key)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
        return direction == .ascending ? sorted : sorted.reversed()
    }

    static func compare(_ lhs: FolderItem, _ rhs: FolderItem, key: ImageSortKey) -> ComparisonResult {
        switch key {
        case .filename:
            return lhs.displayName.localizedStandardCompare(rhs.displayName)
        case .fileExtension:
            let order = ImageSortKey.fileExtension(of: lhs).localizedStandardCompare(ImageSortKey.fileExtension(of: rhs))
            // Within one extension the names still have to be in an order, or the list would
            // reshuffle between scans for no reason the user can see.
            return order != .orderedSame ? order
                : lhs.displayName.localizedStandardCompare(rhs.displayName)
        case .modificationDate:
            return compare(lhs.modificationDate, rhs.modificationDate)
        case .creationDate:
            return compare(lhs.creationDate, rhs.creationDate)
        case .fileSize:
            return compare(lhs.byteSize, rhs.byteSize)
        case .dimensions:
            let lhsPixels = lhs.pixelSize.map { $0.width * $0.height } ?? -1
            let rhsPixels = rhs.pixelSize.map { $0.width * $0.height } ?? -1
            if lhsPixels == rhsPixels { return .orderedSame }
            return lhsPixels < rhsPixels ? .orderedAscending : .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        }
    }
}
