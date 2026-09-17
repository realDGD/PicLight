import Foundation
import CoreGraphics

public enum NavigationDirection: Sendable {
    case forward
    case backward
    case unknown
}

public enum DecodeEvent: Sendable {
    case head(DecodedImageHead)
    case frame(DecodedFrame)
    case failure(String)
}

/// Serializes decode work, keeps only current + neighbours and cancels stale
/// work with generation tokens so a slow decode can never overwrite a newer one.
public actor DecodeCoordinator {
    private let decoder: ImageDecoding
    private var generation = 0
    private var currentTask: Task<Void, Never>?
    private var preloadTasks: [String: Task<Void, Never>] = [:]

    private let cache = DecodeCache()

    public init(decoder: ImageDecoding = ImageIODecoder()) {
        self.decoder = decoder
    }

    public func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// Decodes the requested item and streams head-then-frames. Preloads the
    /// adjacent items at lower priority in the direction of travel.
    public func show(
        item url: URL,
        previous: URL? = nil,
        next: URL? = nil,
        direction: NavigationDirection = .unknown,
        target: DecodeTarget = .fullResolution,
        onEvent: @escaping @Sendable (DecodeEvent) -> Void
    ) -> Task<Void, Never> {
        currentTask?.cancel()
        let token = nextGeneration()
        let decoder = self.decoder
        let cache = self.cache
        cache.setCurrent(url)

        if let cached = cache.head(for: url) {
            onEvent(.head(cached))
            schedulePreload(previous: previous, next: next, direction: direction, target: target)
            return Task {}
        }

        let task = Task(priority: .userInitiated) {
            do {
                let head = try await decoder.decodeFirstDisplayableFrame(url, target: target)
                guard !Task.isCancelled, self.isCurrent(token) else { return }
                cache.store(head: head, for: url)
                onEvent(.head(head))

                let stream = decoder.decodeRemainingFrames(url, descriptor: head.descriptor)
                for try await frame in stream {
                    guard !Task.isCancelled, self.isCurrent(token) else { return }
                    cache.store(frame: frame, for: url)
                    onEvent(.frame(frame))
                }
            } catch {
                // Corrupt files keep navigation alive; the UI shows a compact error
                // that names the file so the user knows which image is unreadable.
                if !Task.isCancelled, self.isCurrent(token) {
                    let reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    onEvent(.failure("无法解码 \(url.lastPathComponent)：\(reason)"))
                }
            }
        }
        currentTask = task
        schedulePreload(previous: previous, next: next, direction: direction, target: target)
        return task
    }

    private func isCurrent(_ token: Int) -> Bool { token == generation }

    /// Neighbour preload order is a pure decision so it can be tested exactly:
    /// forward navigation prioritizes the next image, backward the previous one.
    public static func preloadOrder(previous: URL?, next: URL?,
                                    direction: NavigationDirection) -> [URL] {
        let ordered: [URL?]
        switch direction {
        case .backward: ordered = [previous, next]
        case .forward, .unknown: ordered = [next, previous]
        }
        return ordered.compactMap { $0 }
    }

    private func schedulePreload(previous: URL?, next: URL?, direction: NavigationDirection,
                                 target: DecodeTarget) {
        for url in Self.preloadOrder(previous: previous, next: next, direction: direction)
        where cache.head(for: url) == nil {
            guard preloadTasks[url.path] == nil else { continue }
            let decoder = self.decoder
            let cache = self.cache
            preloadTasks[url.path] = Task(priority: .utility) {
                defer { Task { self.clearPreload(url) } }
                guard let head = try? await decoder.decodeFirstDisplayableFrame(url, target: target) else { return }
                guard !Task.isCancelled else { return }
                cache.store(head: head, for: url)
            }
        }
    }

    private func clearPreload(_ url: URL) { preloadTasks[url.path] = nil }

    public func cancelAll() {
        currentTask?.cancel()
        for task in preloadTasks.values { task.cancel() }
        preloadTasks.removeAll()
    }

    public func purgeCache(keeping url: URL?) { cache.purge(keeping: url) }
}
