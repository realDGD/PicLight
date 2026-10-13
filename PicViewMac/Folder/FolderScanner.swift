import Foundation
import ImageIO

/// Enumerates the current folder only (never subdirectories) and can fill in
/// image dimensions lazily when dimension sorting is requested.
protocol FolderDirectoryScanning: Sendable {
    func scan(directory: URL, excludingExtensions: Set<String>, includingURL: URL?) async throws -> [FolderItem]
}

public struct FolderScanner: Sendable, FolderDirectoryScanning {
    public init() {}

    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey
    ]

    public func scan(containing fileURL: URL) async throws -> [FolderItem] {
        try await Task.detached(priority: .userInitiated) {
            try Self.scanSynchronously(directory: fileURL.deletingLastPathComponent())
        }.value
    }

    public func scan(directory: URL, excludingExtensions: Set<String> = [],
                     includingURL: URL? = nil) async throws -> [FolderItem] {
        try await Task.detached(priority: .userInitiated) {
            try Self.scanSynchronously(directory: directory, excludingExtensions: excludingExtensions,
                                       includingURL: includingURL)
        }.value
    }

    static func scanSynchronously(directory: URL, excludingExtensions: Set<String> = [],
                                  includingURL: URL? = nil) throws -> [FolderItem] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        var items: [FolderItem] = []
        items.reserveCapacity(contents.count)
        for url in contents where SupportedImageTypes.isCandidate(url) {
            if excludingExtensions.contains(url.pathExtension.lowercased()),
               url.lastPathComponent != includingURL?.lastPathComponent { continue }
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            if values?.isDirectory == true || values?.isPackage == true { continue }
            let identity = Self.identity(for: url)
            items.append(FolderItem(
                url: url,
                id: identity,
                byteSize: values?.fileSize.map(Int64.init),
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate
            ))
        }
        return items
    }

    static func identity(for url: URL) -> FileIdentity {
        var inode: UInt64?
        var volume: UInt64?
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        }
        return FileIdentity(url: url, inode: inode, volumeIdentifier: volume)
    }

    /// Reads only the header of each file; used exclusively by dimension sorting.
    public static func fillDimensions(_ items: [FolderItem]) async -> [FolderItem] {
        await Task.detached(priority: .utility) {
            items.map { item in
                var copy = item
                copy.pixelSize = pixelSize(of: item.url)
                return copy
            }
        }.value
    }

    /// Header-only probe; the implementation lives in the imaging layer so the
    /// drawer's oversized decision and dimension sorting can never disagree.
    static func pixelSize(of url: URL) -> CGSize? {
        ImageHeaderProbe.pixelSize(of: url)
    }
}
