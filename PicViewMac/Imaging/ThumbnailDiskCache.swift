import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Decoded thumbnails on disk, keyed by the source file's identity and the requested size.
///
/// The in-memory cache in `ThumbnailPipeline` is bounded and dies with the process; this one survives
/// launches, which is what makes browsing a folder of huge images affordable. Measured with ImageIO
/// on a real 48,000 × 32,000 PNG (1.9 GB): **18 seconds** for a 320 px thumbnail, and the same cost at
/// 64 px or with `kCGImageSourceSubsampleFactor` 16 — ImageIO inflates the whole PNG no matter what is
/// asked for, so the only real optimization is to never do it twice.
///
/// The key is the same version token the decoders use, so a file replaced at the same path can never
/// be served its predecessor's pixels. The store is bounded by total bytes and prunes oldest-first.
public final class ThumbnailDiskCache: @unchecked Sendable {
    /// The cache the app uses unless a test injects its own.
    public static var `default`: ThumbnailDiskCache? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = root
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "PicViewMac", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        return ThumbnailDiskCache(directory: directory)
    }

    public let directory: URL
    private let byteLimit: Int
    private let fileManager: FileManager
    private let lock = NSLock()
    /// Serialises writes and prunes, so two decodes cannot interleave a partial file with a prune.
    private let ioQueue = DispatchQueue(label: "picviewmac.thumbnail-disk-cache")

    public init(directory: URL, byteLimit: Int = 256 * 1024 * 1024,
                fileManager: FileManager = .default) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The image stored for this key, or nil. A hit is a file read plus an ImageIO decode of an
    /// already-small image: microseconds against a full source decode.
    public func thumbnail(forKey key: String) -> CGImage? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Keep it warm for the next prune: usage order, not creation order.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    /// Encodes and stores a thumbnail, and does not return until it is readable.
    ///
    /// Synchronous on purpose. It used to hand the write to a background queue, and a request made
    /// immediately afterwards could read the directory, see the entry and still fail to open it —
    /// the file being replaced under it — then decode the source again. The work here is a PNG encode
    /// of an already-small image (measured: 0 ms against a 187 ms decode for the 16 MP source in the
    /// speed test), so waiting for it costs nothing that matters.
    public func store(_ image: CGImage, forKey key: String) {
        let url = fileURL(forKey: key)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        let payload = data as Data
        ioQueue.sync {
            // Written through a temporary file: a half-written PNG must never be readable as a hit.
            let temporary = url.appendingPathExtension("partial")
            do {
                try payload.write(to: temporary, options: .atomic)
                _ = try? fileManager.replaceItemAt(url, withItemAt: temporary)
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } catch {
                try? fileManager.removeItem(at: temporary)
                return
            }
            pruneIfNeeded()
        }
    }

    public func removeAll() {
        ioQueue.sync {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Total bytes on disk, for tests and diagnostics.
    public var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries().reduce(0) { $0 + $1.size }
    }

    /// The byte limit, for tests that prove the prune keeps the store under it.
    public var byteLimitForTesting: Int { byteLimit }

    public var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries().count
    }

    /// Keeps the store under its byte limit, oldest use first. Called after a write, so the cache
    /// cannot grow without bound just because a folder holds thousands of large images.
    func pruneIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        var entries = self.entries()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }
        entries.sort { $0.used < $1.used }
        let target = byteLimit * 3 / 4
        for entry in entries where total > target {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private struct Entry {
        let url: URL
        let size: Int
        let used: Date
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let listing = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return [] }
        return listing.compactMap { url in
            guard !url.pathExtension.isEmpty, url.pathExtension != "partial",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return Entry(url: url, size: values.fileSize ?? 0,
                         used: values.contentModificationDate ?? .distantPast)
        }
    }

    /// A stable file name for a key, so a version token (which contains path-ish characters) cannot
    /// escape the directory or collide with another key.
    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }
}
