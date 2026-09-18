import Foundation

/// Which file a decode belongs to.
///
/// A path is not an identity: an editor that saves over `photo.png` keeps the path and changes
/// the bytes, and the tile cache — which is keyed by path — then serves the previous file's
/// pixels. `URL.resourceValues(forKeys:)` is not an identity either, because it answers from a
/// per-URL cache that a replacement does not invalidate (measured here: the old size and date
/// were still reported ten seconds after the file at that path had been rewritten).
///
/// `stat(2)` is. It is one syscall, it reads no file contents, and it reports the file's own
/// metadata as it is now. The fields are the ones that survive the ways a file can be replaced:
///
/// - `fileSize` and `modificationTime` catch an ordinary save
/// - `changeTime` catches a replacement that restores both (an editor writing a temp file into
///   place, or a copy run with `touch -r`), and also a fast replacement inside one clock tick
///   where the modification time may not have advanced far enough to be distinguishable
/// - `inode` and `volumeIdentifier` catch a *different* file arriving at the same path — a move,
///   an atomic replace, or a mount change — even when every timestamp matches
///
/// Deliberately no content hash: identity is read on every viewport request, and reading the
/// file to ask whether it changed would cost more than the decode it guards.
public struct SourceFileIdentity: Hashable, Sendable {
    /// The path exactly as the tile cache spells it (`NativeTileKey.sourcePath`), so a version
    /// recorded under it is the one found when a tile for that key is stored.
    public let path: String
    /// The canonical spelling, with `.`/`..` and duplicate separators resolved. Equal for two
    /// spellings of one path; the tile cache's own key stays exact for compatibility.
    public let canonicalPath: String
    /// `-1` when the file is missing, so `exists` stays the single question callers ask.
    public let fileSize: Int64
    public let modificationTime: TimeInterval
    /// The inode's change time. Not the creation time: this is the field that moves when a file
    /// is replaced by another one at the same path.
    public let changeTime: TimeInterval
    public let inode: UInt64?
    public let volumeIdentifier: UInt64?
    public let exists: Bool

    public init(path: String, canonicalPath: String, fileSize: Int64,
                modificationTime: TimeInterval, changeTime: TimeInterval,
                inode: UInt64?, volumeIdentifier: UInt64?, exists: Bool) {
        self.path = path
        self.canonicalPath = canonicalPath
        self.fileSize = fileSize
        self.modificationTime = modificationTime
        self.changeTime = changeTime
        self.inode = inode
        self.volumeIdentifier = volumeIdentifier
        self.exists = exists
    }

    /// Reads the file's metadata. One `stat`, no contents, no cached copy.
    public static func read(at url: URL) -> SourceFileIdentity {
        let canonical = url.standardizedFileURL.path
        // `stat`, not `lstat`: the pixels come from the file the path resolves to, so a symlink
        // repointed at a different image is a replacement and must read as one.
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            return SourceFileIdentity(path: url.path, canonicalPath: canonical,
                                      fileSize: -1, modificationTime: -1, changeTime: -1,
                                      inode: nil, volumeIdentifier: nil, exists: false)
        }
        return SourceFileIdentity(
            path: url.path,
            canonicalPath: canonical,
            fileSize: Int64(info.st_size),
            modificationTime: Self.seconds(info.st_mtimespec),
            changeTime: Self.seconds(info.st_ctimespec),
            inode: UInt64(info.st_ino),
            volumeIdentifier: UInt64(info.st_dev),
            exists: true)
    }

    private static func seconds(_ time: timespec) -> TimeInterval {
        TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    /// The value the tile cache compares. A string because the cache's map is keyed by path and
    /// this is the cheap "same file?" question asked per store; the identity itself is the type
    /// the thumbnail cache will share.
    public var versionToken: String {
        guard exists else { return "missing" }
        let inodePart = inode.map(String.init) ?? "-"
        let volumePart = volumeIdentifier.map(String.init) ?? "-"
        // Nanosecond-resolution times: `TimeInterval` is a Double, and at 1.7e9 seconds a
        // nanosecond is below its resolution, so the raw seconds are formatted separately from
        // the nanosecond field rather than summed.
        return "\(fileSize)-\(changeTime)-\(modificationTime)-\(inodePart)-\(volumePart)"
    }

    /// Same bytes, same metadata, same file.
    public func refersToSameFile(as other: SourceFileIdentity) -> Bool {
        if path == other.path { return true }
        if let inode, let volumeIdentifier,
           let otherInode = other.inode, let otherVolume = other.volumeIdentifier {
            return inode == otherInode && volumeIdentifier == otherVolume
        }
        return false
    }
}
