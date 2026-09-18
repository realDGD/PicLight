import CoreGraphics
import Foundation

/// Identity of one native-detail tile.
///
/// Deliberately *not* part of the key: view-only rotation and mirroring. They are view
/// transforms, so baking them into decode identity would make the same pixels cache as
/// several different tiles. Page and level are part of it, because a TIFF page and a
/// decode level are different pixels.
public struct NativeTileKey: Hashable, Sendable {
    public let sourcePath: String
    public let pageIndex: Int
    /// 0 is the source's own resolution; higher levels are reserved for a future
    /// pyramid and are not produced yet.
    public let level: Int
    public let x: Int
    public let y: Int
    /// The grid the coordinates belong to. Without it a 64-pixel tile and a 128-pixel tile at
    /// the same cell share a key, and a cached texture from the finer grid gets stretched over
    /// the coarser tile's quad — measured as a registration error of 55/255 on a probe that
    /// renders the same scene through both renderers.
    public let tileSize: Int

    public init(sourcePath: String, pageIndex: Int = 0, level: Int = 0,
                tileSize: Int, x: Int, y: Int) {
        self.sourcePath = sourcePath
        self.pageIndex = pageIndex
        self.level = level
        self.tileSize = tileSize
        self.x = x
        self.y = y
    }
}

/// One decoded native-detail tile.
public struct NativeTile: @unchecked Sendable {
    public let key: NativeTileKey
    /// Where the image belongs in source pixel space. It may extend one pixel past the
    /// tile's nominal rect (the gutter) and is clipped at the image edges; adjoining tiles
    /// overlap in that pixel, which is harmless because the overlapping pixels are the
    /// same pixels.
    public let sourceRect: CGRect
    /// Premultiplied RGBA8, including the gutter.
    public let image: CGImage

    public var byteCost: Int { image.bytesPerRow * image.height }
}

/// One tile position in the grid.
public struct TileCoordinate: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// What a viewport needs from the native-detail backend.
public struct NativeTilePlan: Equatable, Sendable {
    public let tileSize: Int
    /// Tiles intersecting the visible source rectangle, nearest to its centre first.
    public let visible: [TileCoordinate]
    /// The one-ring around them, in the same order — prefetched, never drawn until they
    /// become visible.
    public let ring: [TileCoordinate]
    /// Union of everything in the plan, clipped to the image, in source pixels.
    public let decodeRect: CGRect

    public var allCoordinates: [TileCoordinate] { visible + ring }
}

public enum NativeTilePlanner {
    /// The source rectangle a viewport is actually looking at.
    ///
    /// The view rectangle is mapped back through the *same* transform the renderers use,
    /// so rotation and mirroring are handled by construction rather than by a second
    /// implementation of the geometry.
    public static func visibleSourceRect(viewport: ViewportState,
                                         sourcePixelSize: CGSize,
                                         viewSize: CGSize) -> CGRect {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let transform = viewport.imageToViewTransform(sourcePixelSize: sourcePixelSize,
                                                     viewSize: viewSize)
        let inverse = transform.inverted()
        let centred = CGRect(origin: .zero, size: viewSize).applying(inverse)
        // The transform works in *centred, y-up* source coordinates; tiles are indexed in
        // top-left coordinates. Converting is a translation and a flip — `centredSourceRect`
        // in reverse — and a plain translation would name the wrong part of the image
        // (the test caught exactly that: y 500 read back as 1500).
        let inSource = CGRect(x: centred.minX + sourcePixelSize.width / 2,
                              y: sourcePixelSize.height / 2 - centred.maxY,
                              width: centred.width, height: centred.height)
        return inSource.intersection(CGRect(origin: .zero, size: sourcePixelSize))
    }

    /// Does the bitmap on screen still resolve one source pixel per backing pixel?
    ///
    /// The proxy covers `proxyLongEdge` texels for `sourceLongEdge` source pixels, so it
    /// is adequate while `physicalScale` (backing pixels per source pixel) stays below
    /// that ratio. A 15 % margin keeps a viewport hovering at the boundary from asking
    /// for tiles it does not need.
    public static func needsNativeDetail(sourceLongEdge: Int,
                                         proxyLongEdge: Int,
                                         physicalScale: CGFloat) -> Bool {
        guard sourceLongEdge > DecodeBudget.maximumLongEdge,
              proxyLongEdge > 0, physicalScale.isFinite, physicalScale > 0 else { return false }
        let ratio = CGFloat(proxyLongEdge) / CGFloat(sourceLongEdge)
        return physicalScale > ratio * 1.15
    }

    /// Tiles covering `sourceRect` plus a one-ring, nearest-first.
    public static func plan(sourceRect: CGRect,
                            sourcePixelSize: CGSize,
                            tileSize: Int,
                            ring: Int = 1) -> NativeTilePlan? {
        guard tileSize > 0, sourceRect.width >= 1, sourceRect.height >= 1 else { return nil }
        let columns = Int(ceil(sourcePixelSize.width / CGFloat(tileSize)))
        let rows = Int(ceil(sourcePixelSize.height / CGFloat(tileSize)))

        func range(_ minValue: CGFloat, _ maxValue: CGFloat, _ count: Int) -> ClosedRange<Int> {
            let first = max(0, Int(floor(minValue / CGFloat(tileSize))))
            let last = min(count - 1, Int(ceil(maxValue / CGFloat(tileSize))) - 1)
            return first...max(first, last)
        }
        let xRange = range(sourceRect.minX, sourceRect.maxX, columns)
        let yRange = range(sourceRect.minY, sourceRect.maxY, rows)

        let centre = CGPoint(x: sourceRect.midX / CGFloat(tileSize),
                             y: sourceRect.midY / CGFloat(tileSize))
        func distance(_ coordinate: TileCoordinate) -> CGFloat {
            let dx = CGFloat(coordinate.x) + 0.5 - centre.x
            let dy = CGFloat(coordinate.y) + 0.5 - centre.y
            return hypot(dx, dy)
        }

        var visible: [TileCoordinate] = []
        var ringTiles: [TileCoordinate] = []
        for y in yRange {
            for x in xRange {
                visible.append(.init(x: x, y: y))
            }
        }
        for y in max(0, yRange.lowerBound - ring)...min(rows - 1, yRange.upperBound + ring) {
            for x in max(0, xRange.lowerBound - ring)...min(columns - 1, xRange.upperBound + ring) {
                guard !xRange.contains(x) || !yRange.contains(y) else { continue }
                ringTiles.append(.init(x: x, y: y))
            }
        }
        visible.sort { distance($0) < distance($1) }
        ringTiles.sort { distance($0) < distance($1) }

        let unionX = max(0, xRange.lowerBound - ring)
        let unionY = max(0, yRange.lowerBound - ring)
        let unionMaxX = min(columns - 1, xRange.upperBound + ring)
        let unionMaxY = min(rows - 1, yRange.upperBound + ring)
        let decodeRect = CGRect(x: CGFloat(unionX * tileSize), y: CGFloat(unionY * tileSize),
                                width: CGFloat((unionMaxX - unionX + 1) * tileSize),
                                height: CGFloat((unionMaxY - unionY + 1) * tileSize))
            .intersection(CGRect(origin: .zero, size: sourcePixelSize))

        return NativeTilePlan(tileSize: tileSize, visible: visible, ring: ringTiles,
                              decodeRect: decodeRect)
    }

    /// The source rectangle of one tile, clipped to the image.
    public static func sourceRect(for coordinate: TileCoordinate,
                                  tileSize: Int,
                                  sourcePixelSize: CGSize) -> CGRect {
        CGRect(x: CGFloat(coordinate.x * tileSize), y: CGFloat(coordinate.y * tileSize),
               width: CGFloat(tileSize), height: CGFloat(tileSize))
            .intersection(CGRect(origin: .zero, size: sourcePixelSize))
    }
}

/// Byte-budgeted tile cache.
///
/// Cost is the real decoded size, not a tile count: 512×512 tiles of different sources
/// are not the same thing, and a count limit lets a budget blow up when the tile size
/// changes. Visible tiles are *pinned* — the one thing an LRU must never do is evict what
/// the user is looking at (the earlier cache work already found `NSCache` doing exactly
/// that to the on-screen entry).
public final class NativeTileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NativeTileKey: Entry] = [:]
    private var pinned: Set<NativeTileKey> = []
    private var clock: UInt64 = 0
    private var storedBytes = 0

    /// Drops every tile that is not from `sourcePath`. Used when a pass starts for a different
    /// source: its tiles are useless and would otherwise hold budget until eviction reached them.
    /// A request for the same source keeps them, so a disable → re-enable stays warm.
    public func purge(exceptSourcePath path: String) {
        lock.lock(); defer { lock.unlock() }
        var removed = 0
        for (key, entry) in entries where key.sourcePath != path {
            storedBytes -= entry.cost
            pinned.remove(key)
            entries.removeValue(forKey: key)
            removed += 1
        }
        purgedForSourceChange += removed
    }

    /// Tiles dropped because the pass moved to another source.
    public private(set) var purgedForSourceChange = 0

    public var totalCostLimit: Int
    /// Evicted because the budget was reached — a number a test can assert on.
    public private(set) var evictionCount = 0
    public private(set) var hitCount = 0

    private struct Entry {
        let tile: NativeTile
        let cost: Int
        var used: UInt64
        /// The version of the source file this tile was decoded from. Compared against the version
        /// the scheduler reports, so a file replaced at the same path can never be served from the
        /// previous file's pixels — the key stays path-based, so no caller can build a mismatched one.
        var sourceVersion: String
    }

    /// Identity of the file the tiles for this path came from: size and modification date together,
    /// because neither alone survives a fast replacement. Changing it drops that path's tiles.
    public func setSourceVersion(_ version: String, for path: String) {
        lock.lock(); defer { lock.unlock() }
        sourceVersions[path] = version
        for (key, entry) in entries where key.sourcePath == path && entry.sourceVersion != version {
            storedBytes -= entry.cost
            pinned.remove(key)
            entries.removeValue(forKey: key)
            versionMismatches += 1
        }
    }

    /// Tiles dropped because their source file was replaced.
    public private(set) var versionMismatches = 0

    private var sourceVersions: [String: String] = [:]

    public init(totalCostLimit: Int = 192 * 1024 * 1024) {
        self.totalCostLimit = totalCostLimit
    }

    public var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storedBytes
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public var pinnedKeys: Set<NativeTileKey> {
        lock.lock(); defer { lock.unlock() }
        return pinned
    }

    public func tile(for key: NativeTileKey) -> NativeTile? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.used = clock
        entries[key] = entry
        hitCount += 1
        return entry.tile
    }

    public func store(_ tile: NativeTile) {
        lock.lock(); defer { lock.unlock() }
        clock += 1
        if let existing = entries[tile.key] { storedBytes -= existing.cost }
        let cost = tile.byteCost
        entries[tile.key] = Entry(tile: tile, cost: cost, used: clock,
                                  sourceVersion: sourceVersions[tile.key.sourcePath] ?? "")
        storedBytes += cost
        evictIfNeeded()
    }

    /// Pins the tiles a viewport shows and drops everything else from the pin set.
    public func pin(_ keys: Set<NativeTileKey>) {
        lock.lock(); defer { lock.unlock() }
        pinned = keys
    }

    public func purge(keeping keys: Set<NativeTileKey> = []) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { keys.contains($0.key) }
        pinned = pinned.intersection(keys)
        storedBytes = entries.values.reduce(0) { $0 + $1.cost }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        pinned.removeAll()
        storedBytes = 0
    }

    /// Evicts least-recently-used unpinned tiles until the budget is met. Pinned tiles can
    /// push the cache over budget; that is deliberate — the alternative is evicting the
    /// viewport the user is looking at, and the planned viewport is small by construction.
    private func evictIfNeeded() {
        guard storedBytes > totalCostLimit else { return }
        let candidates = entries
            .filter { !pinned.contains($0.key) }
            .sorted { $0.value.used < $1.value.used }
        for (key, entry) in candidates {
            guard storedBytes > totalCostLimit else { break }
            entries.removeValue(forKey: key)
            storedBytes -= entry.cost
            evictionCount += 1
        }
    }
}

/// What the viewer needs to know about the backend, for tests and for the acceptance
/// report: passes started, tiles delivered, cache occupancy.
public struct NativeDetailStats: Equatable, Sendable {
    public var passes = 0
    public var tilesDelivered = 0
    public var cachedTiles = 0
    public var cachedBytes = 0
    public var evictions = 0
    public var lastErrorDescription: String?
}
