import Foundation
import CoreGraphics

public enum PlaybackState: Equatable, Sendable {
    case staticImage
    case playing
    case paused
}

/// Viewer-side state: what to draw, how it plays and which chrome is visible.
/// Window geometry (including native full screen) is deliberately not mirrored here.
@MainActor
public final class ViewerState {
    public var playback: PlaybackState = .staticImage
    public var frameIndex: Int = 0
    public var pageIndex: Int = 0
    public var isImmersive: Bool = false
    public var errorMessage: String?

    public private(set) var descriptor: ImageDescriptor?
    public private(set) var metadata: ImageMetadata?
    public private(set) var currentImage: CGImage?
    public var viewport = ViewportState()

    public var onImageChanged: (() -> Void)?
    public var onPlaybackChanged: (() -> Void)?

    public init() {}

    public var isAnimated: Bool { descriptor?.animated == true }
    public var isMultiPage: Bool { (descriptor?.pageCount ?? 1) > 1 }
    public var pageDescription: String? {
        guard isMultiPage, let descriptor else { return nil }
        return "\(pageIndex + 1) / \(descriptor.pageCount)"
    }

    public func apply(head: DecodedImageHead) {
        descriptor = head.descriptor
        metadata = head.metadata
        currentImage = head.image
        frameIndex = 0
        pageIndex = 0
        errorMessage = nil
        playback = head.descriptor.animated ? .playing : .staticImage
        BenchTrace.mark("T5 ViewerState.apply(head:) — image published to UI")
        fitScaleForCurrentImage()
        onImageChanged?()
        onPlaybackChanged?()
    }

    public func apply(frame: DecodedFrame) {
        currentImage = frame.image
        frameIndex = frame.index
        onImageChanged?()
    }

    /// A folder with no supported images is a normal state, not an error.
    public func applyEmptyState() {
        currentImage = nil
        descriptor = nil
        metadata = nil
        errorMessage = nil
        playback = .staticImage
        frameIndex = 0
        pageIndex = 0
        onImageChanged?()
        onPlaybackChanged?()
    }

    public func apply(error: String) {
        errorMessage = error
        currentImage = nil
        descriptor = nil
        metadata = nil
        playback = .staticImage
        onImageChanged?()
        onPlaybackChanged?()
    }

    /// Any image switch stops the animation clock; revisiting restarts at frame 0.
    public func clearForNewImage() {
        playback = .staticImage
        frameIndex = 0
        pageIndex = 0
        currentImage = nil
        viewport = ViewportState()
    }

    public func togglePlayback() {
        guard isAnimated else { return }
        playback = playback == .playing ? .paused : .playing
        onPlaybackChanged?()
    }

    public func pausePlayback() {
        guard playback == .playing else { return }
        playback = .paused
        onPlaybackChanged?()
    }

    public func resumePlayback() {
        guard isAnimated, playback == .paused else { return }
        playback = .playing
        onPlaybackChanged?()
    }

    /// Immersive toggling changes chrome policy only; window geometry is untouched.
    public func toggleImmersive() {
        isImmersive.toggle()
    }

    // MARK: - Viewport commands

    public func fitScaleFor(imagePixels: CGSize, viewPoints: CGSize) -> CGFloat {
        ViewportState.fitScale(imagePixels: imagePixels, viewPoints: viewPoints)
    }

    public func updateFitScale(imagePixels: CGSize, viewPoints: CGSize) {
        viewport.fitScale = fitScaleFor(imagePixels: imagePixels, viewPoints: viewPoints)
        viewport.clampCenter(imagePixels: imagePixels, viewPoints: viewPoints, backingScale: 1)
    }

    private func fitScaleForCurrentImage() {
        guard let descriptor else { return }
        viewport = ViewportState(
            fitScale: viewport.fitScale,
            zoomScale: viewport.fitScale,
            normalizedCenter: CGPoint(x: 0.5, y: 0.5)
        )
        _ = descriptor
    }

    public func setZoomToFit(imagePixels: CGSize, viewPoints: CGSize) {
        updateFitScale(imagePixels: imagePixels, viewPoints: viewPoints)
        viewport.zoomScale = viewport.fitScale
        viewport.normalizedCenter = CGPoint(x: 0.5, y: 0.5)
    }

    public func setZoomToFitWidth(imagePixels: CGSize, viewPoints: CGSize) {
        updateFitScale(imagePixels: imagePixels, viewPoints: viewPoints)
        viewport.zoomScale = ViewportState.fitWidthScale(imagePixels: imagePixels,
                                                        viewPoints: viewPoints)
        viewport.normalizedCenter = CGPoint(x: 0.5, y: 0.5)
    }

    public func setZoomToActualPixels(backingScale: CGFloat) {
        viewport.zoomScale = ViewportState.actualPixelScale(backingScale: backingScale)
    }

    public func toggleFitAndDoubleFit(imagePixels: CGSize, viewPoints: CGSize) {
        let fit = fitScaleFor(imagePixels: imagePixels, viewPoints: viewPoints)
        if viewport.isAtFit {
            viewport.fitScale = fit
            viewport.zoomScale = ViewportState.doubleFitScale(fit: fit)
        } else {
            viewport.fitScale = fit
            viewport.zoomScale = fit
            viewport.normalizedCenter = CGPoint(x: 0.5, y: 0.5)
        }
    }
}
