import Foundation

/// Stable identity for a folder item so that rescans, sorts and renames do not
/// silently move the user to a different file.
public struct FileIdentity: Hashable, Sendable, Comparable {
    public let path: String
    public let inode: UInt64?
    public let volumeIdentifier: UInt64?

    public init(url: URL, inode: UInt64? = nil, volumeIdentifier: UInt64? = nil) {
        self.path = url.standardizedFileURL.path
        self.inode = inode
        self.volumeIdentifier = volumeIdentifier
    }

    public static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    public static func < (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.path < rhs.path
    }

    /// Same file even if the path changed (rename inside the watched folder).
    public func refersToSameFile(as other: FileIdentity) -> Bool {
        if self == other { return true }
        if let inode, let volumeIdentifier,
           let otherInode = other.inode, let otherVolume = other.volumeIdentifier {
            return inode == otherInode && volumeIdentifier == otherVolume
        }
        return false
    }
}
