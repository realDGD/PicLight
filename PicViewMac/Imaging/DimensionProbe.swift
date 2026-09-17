import Foundation
import CoreGraphics

/// C2 dimension probing (spec §14.1): read an image header only when a decision
/// actually needs the source size, and remember the answer.
///
/// Byte size is deliberately *not* an input to the decision: the C-series
/// benchmark showed it cannot classify the supported formats in either direction
/// (a 2.5 MB PNG measured 12000×12000; a 148 MB PNG measured 8192×5461).
/// What `DecodeCoordinator` needs in order to predict a cache level and to keep
/// oversized neighbours out of the preload path. Injectable so tests can describe
/// a folder without real files on disk.
public protocol DimensionProbing: Sendable {
    func longEdge(of url: URL) async -> Int?
}

extension DimensionProbing {
    /// Convenience for policy decisions, which must fail safe: an unreadable header
    /// counts as oversized, so nothing speculative starts for it.
    public func isOversized(_ url: URL) async -> Bool {
        OversizedPolicy.isOversized(sourceLongEdge: await longEdge(of: url))
    }
}

public actor DimensionProbe: DimensionProbing {
    private var longEdges: [String: Int] = [:]
    private var inFlight: [String: Task<Int?, Never>] = [:]

    public init() {}

    /// Longest source edge in pixels, or nil when the header cannot be read.
    public func longEdge(of url: URL) async -> Int? {
        if let cached = longEdges[url.path] { return cached }
        if let existing = inFlight[url.path] { return await existing.value }

        let task = Task.detached(priority: .utility) { () -> Int? in
            DimensionProbe.readLongEdge(of: url)
        }
        inFlight[url.path] = task
        let value = await task.value
        inFlight[url.path] = nil
        if let value { longEdges[url.path] = value }
        return value
    }

    public func forget(_ url: URL) { longEdges[url.path] = nil }

    /// Number of remembered dimensions; for tests and diagnostics.
    public func cachedCount() -> Int { longEdges.count }

    /// Header-only read — no pixel decode. Uses the shared imaging-layer probe so
    /// folder scanning and drawer decisions cannot disagree about a file's size.
    nonisolated static func readLongEdge(of url: URL) -> Int? {
        guard let pixelSize = ImageHeaderProbe.pixelSize(of: url) else { return nil }
        let longEdge = Int(max(pixelSize.width, pixelSize.height).rounded())
        return longEdge > 0 ? longEdge : nil
    }
}
