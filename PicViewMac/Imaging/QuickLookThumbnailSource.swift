import Foundation
import CoreGraphics
import QuickLookThumbnailing

/// macOS's own thumbnail cache, asked opportunistically.
///
/// Measured on the user's 48,000 × 32,000 PNG (1.9 GB):
///
/// | path | time |
/// |---|---|
/// | Quick Look, system cache warm | **23 ms** |
/// | Quick Look, cache cold (fresh copy) | **20.7 s** |
/// | full ImageIO decode of the same file | **18.8 s** |
/// | ImageIO on an ordinary 1946 × 1248 JPEG | **3.4 ms** |
/// | Quick Look on that same JPEG | 195 ms |
///
/// So Quick Look is worth exactly one thing: a free ride when macOS already holds the thumbnail
/// (Finder normally makes one when the folder has been looked at). It is *slower* than decoding in
/// process for ordinary pictures, because every request is an XPC round trip, so it is only consulted
/// where a decode is known to be expensive. And it must never be waited on: a cold request takes as
/// long as the decode it was meant to avoid, so the caller time-boxes it and keeps the answer if it
/// arrives late.
public protocol QuickLookThumbnailProviding: Sendable {
    /// Starts one low-quality request. `completion` runs exactly once, however long the system takes.
    ///
    /// Deliberately not `async`: the caller has to be able to give up while the request keeps
    /// running, and a continuation cannot be resumed twice.
    func requestLowQualityThumbnail(for url: URL, maxPixelSize: Int,
                                    completion: @escaping @Sendable (CGImage?) -> Void)
}

/// The system generator.
public struct SystemQuickLookThumbnails: QuickLookThumbnailProviding {
    public init() {}

    public func requestLowQualityThumbnail(for url: URL, maxPixelSize: Int,
                                           completion: @escaping @Sendable (CGImage?) -> Void) {
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: 1,
            representationTypes: .lowQualityThumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.cgImage)
        }
    }
}

/// Resumes a continuation at most once.
///
/// A timed-out request is not cancelled — its answer warms the cache instead — so both the completion
/// and the timer race to resume the same continuation, and only the first may win.
public final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    public init() {}

    /// - Returns: whether this call was the one that resumed the continuation.
    @discardableResult
    public func resume(_ continuation: CheckedContinuation<CGImage?, Never>,
                       with image: CGImage?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        continuation.resume(returning: image)
        return true
    }
}

/// A source that answers with whatever it is handed, for tests. Bounded by a policy so a test can say
/// "answers immediately", "answers after the budget" or "never answers".
public final class StubQuickLookThumbnails: QuickLookThumbnailProviding, @unchecked Sendable {
    public enum Behaviour: Sendable {
        /// Answer now with this image.
        case answer(CGImage)
        /// Answer after this many seconds (used to prove the budget is honoured and the late answer
        /// is still kept).
        case answerAfter(TimeInterval, CGImage)
        /// Never answer at all.
        case never
    }

    private let behaviour: Behaviour
    private let lock = NSLock()
    private var requestCount = 0

    public init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    public var requestCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    public func requestLowQualityThumbnail(for url: URL, maxPixelSize: Int,
                                           completion: @escaping @Sendable (CGImage?) -> Void) {
        lock.lock(); requestCount += 1; lock.unlock()
        switch behaviour {
        case let .answer(image):
            completion(image)
        case let .answerAfter(delay, image):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(image) }
        case .never:
            break
        }
    }
}
