import Foundation

/// A file timestamp that keeps both fields as integers.
///
/// Deliberately not a `TimeInterval`: a `Double` at current epoch seconds (~1.7e9) cannot
/// represent a nanosecond — its ulp there is ≈238 ns — so two files changed within one clock tick
/// would collapse into one value and the identity would silently stop distinguishing them. Keeping
/// `seconds` and `nanoseconds` apart preserves exactly what `stat(2)` reported.
public struct FileTimestamp: Hashable, Sendable, CustomStringConvertible {
    public let seconds: Int64
    /// 0 ..< 1_000_000_000, as `timespec` reports it.
    public let nanoseconds: Int64

    public init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public var description: String {
        String(format: "%lld.%09lld", seconds, nanoseconds)
    }
}

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
    public let modificationTime: FileTimestamp
    /// The inode's change time. Not the creation time: this is the field that moves when a file
    /// is replaced by another one at the same path.
    public let changeTime: FileTimestamp
    public let inode: UInt64?
    public let volumeIdentifier: UInt64?
    public let exists: Bool

    public init(path: String, canonicalPath: String, fileSize: Int64,
                modificationTime: FileTimestamp, changeTime: FileTimestamp,
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
                                      fileSize: -1,
                                      modificationTime: FileTimestamp(seconds: -1, nanoseconds: 0),
                                      changeTime: FileTimestamp(seconds: -1, nanoseconds: 0),
                                      inode: nil, volumeIdentifier: nil, exists: false)
        }
        return SourceFileIdentity(
            path: url.path,
            canonicalPath: canonical,
            fileSize: Int64(info.st_size),
            modificationTime: Self.timestamp(info.st_mtimespec),
            changeTime: Self.timestamp(info.st_ctimespec),
            inode: UInt64(info.st_ino),
            volumeIdentifier: UInt64(info.st_dev),
            exists: true)
    }

    /// `timespec` → `FileTimestamp`, field for field, so nothing is lost on the way.
    private static func timestamp(_ time: timespec) -> FileTimestamp {
        FileTimestamp(seconds: Int64(time.tv_sec), nanoseconds: Int64(time.tv_nsec))
    }

    /// The value the cache compares. A string because the cache's map is keyed by path and
    /// this is the cheap "same file?" question asked per store; the identity itself is the type
    /// the thumbnail cache will share.
    ///
    /// Deliberately *not* a function of the path: the question this answers is "is the file at *this
    /// path* still the file the tiles were decoded from", and the path is the map's key. Two
    /// different files that happen to share a size, timestamps and inode number on different
    /// volumes would share a token — and it would not matter, because they are never compared.
    public var versionToken: String {
        guard exists else { return "missing" }
        let inodePart = inode.map(String.init) ?? "-"
        let volumePart = volumeIdentifier.map(String.init) ?? "-"
        // The timestamps keep seconds and nanoseconds as integers (`FileTimestamp`), so the token
        // preserves the full precision `stat(2)` reported — a Double could not at epoch scale.
        return "\(fileSize)-\(changeTime)-\(modificationTime)-\(inodePart)-\(volumePart)"
    }

    /// Same bytes, same metadata, same file, however the path is spelled. Two spellings of one
    /// path (`/var/…` and `/private/var/…`) stat the same file and so are the same file; a
    /// replacement at a path changes the metadata and is a different file. Deliberately compares
    /// the file's own fields, not the path: the path is where the file sits, not what it is.
    /// (A missing file has nothing to compare, so the answer falls back to location.)
    public func refersToSameFile(as other: SourceFileIdentity) -> Bool {
        guard exists, other.exists else { return refersToSameLocation(as: other) }
        return fileSize == other.fileSize
            && modificationTime == other.modificationTime
            && changeTime == other.changeTime
            && inode == other.inode
            && volumeIdentifier == other.volumeIdentifier
    }

    /// The same place on disk, however it is spelled: same path or same canonical path. This is a
    /// *location* question — `/var/x.png` and `/private/var/x.png` are one location — and it
    /// deliberately knows nothing about whether the file at that location is still the same file.
    public func refersToSameLocation(as other: SourceFileIdentity) -> Bool {
        if path == other.path { return true }
        if canonicalPath == other.canonicalPath { return true }
        return false
    }
}