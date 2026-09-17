import AppKit

/// Single entry point for every way a file can be opened: Finder double-click,
/// Open With, `⌘O`, drag onto the app and `open -a`.
@MainActor
public final class FileOpenCoordinator {
    /// Overridable default from settings; modifier inversion is resolved in the
    /// command layer, never here.
    public var behaviorProvider: () -> OpenBehavior = { AppSettings.shared.openBehavior }
    public var openHandler: ((URL, OpenBehavior) -> Void)?

    public init() {}

    public func open(urls: [URL], behavior: OpenBehavior? = nil) {
        let resolved = behavior ?? behaviorProvider()
        let supported = urls.filter { SupportedImageTypes.isCandidate($0) }
        guard !supported.isEmpty else { return }
        for (offset, url) in supported.enumerated() {
            // The first file honors the configured behavior; additional files from
            // one drop always get their own window so nothing is silently dropped.
            let effective: OpenBehavior = offset == 0 ? resolved : .newWindow
            openHandler?(url, effective)
        }
    }

    public func open(url: URL, behavior: OpenBehavior? = nil) {
        open(urls: [url], behavior: behavior)
    }
}
