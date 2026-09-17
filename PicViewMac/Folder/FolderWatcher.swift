import Foundation

/// Watches only the active directory through a file descriptor source. Events
/// are debounced and never recurse into children.
///
/// The descriptor is owned exclusively by the dispatch source's cancel handler,
/// so it is closed exactly once; closing it from `stop()` as well would risk
/// closing a descriptor number that had already been reused by another reader.
public final class FolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.picviewmac.folderwatcher")
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?

    public var debounceInterval: TimeInterval = 0.35
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    deinit { stop() }

    public func start(watching directory: URL) {
        stop()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleNotification() }
        // Sole owner of the descriptor: cancel is the only place that closes it.
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    public func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        guard let source else { return }
        self.source = nil
        source.cancel()
    }

    private func scheduleNotification() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onChange?()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
