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
    /// One remembered answer, with the version of the file it was read from.
    private struct Entry {
        let version: String
        let longEdge: Int
    }

    private var longEdges: [String: Entry] = [:]
    private var inFlight: [String: InFlight] = [:]

    public init() {}

    /// Longest source edge in pixels, or nil when the header cannot be read.
    ///
    /// The remembered answer belongs to a *version* of the file, not to its path: an editor saving
    /// over the path changes the bytes, and a path-keyed answer then kept classifying the new file by
    /// the old one's size — measured as a 32×24 replacement still answering 8192. The version is one
    /// `stat`, and the answer is only reused when it still describes the file at that path.
    /// A read in flight, and the version it is reading. Joined only by requests for the same
    /// version: a file replaced while its header is being read is a different question, and reusing
    /// the old answer would classify the new file by the old one's size.
    private struct InFlight {
        let version: String
        let task: Task<Int?, Never>
    }

    public func longEdge(of url: URL) async -> Int? {
        let version = SourceFileIdentity.read(at: url).versionToken
        if let cached = longEdges[url.path], cached.version == version { return cached.longEdge }
        if let existing = inFlight[url.path], existing.version == version {
            return await existing.task.value
        }

        let task = Task.detached(priority: .utility) { () -> Int? in
            DimensionProbe.readLongEdge(of: url)
        }
        inFlight[url.path] = InFlight(version: version, task: task)
        let value = await task.value
        // Only the request that started this read may clear it: a newer version may have replaced
        // the entry while this one was suspended.
        if inFlight[url.path]?.version == version { inFlight[url.path] = nil }
        if let value { longEdges[url.path] = Entry(version: version, longEdge: value) }
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
