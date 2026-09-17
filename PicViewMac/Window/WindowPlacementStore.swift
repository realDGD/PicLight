import AppKit

/// Pure geometry for window sizing so it can be unit tested without a screen.
public enum WindowPlacementStore {
    /// Clamps a remembered or image-derived frame into the screen's visible frame,
    /// which also recovers from a disconnected monitor.
    public static func clamp(_ frame: NSRect, into visibleFrame: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(max(result.width, 320), visibleFrame.width)
        result.size.height = min(max(result.height, 240), visibleFrame.height)
        result.origin.x = min(max(result.origin.x, visibleFrame.minX),
                              visibleFrame.maxX - result.size.width)
        result.origin.y = min(max(result.origin.y, visibleFrame.minY),
                              visibleFrame.maxY - result.size.height)
        return result
    }

    /// Window frame that shows the image at 100% when it fits the usable screen,
    /// otherwise falls back to a Fit-sized frame.
    public static func imageSizedFrame(imagePixels: CGSize, chromeInsets: NSEdgeInsets,
                                       visibleFrame: NSRect) -> NSRect {
        let usableWidth = visibleFrame.width - chromeInsets.left - chromeInsets.right
        let usableHeight = visibleFrame.height - chromeInsets.top - chromeInsets.bottom
        let width = min(imagePixels.width, usableWidth)
        let height = min(imagePixels.height, usableHeight)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width + chromeInsets.left + chromeInsets.right,
            height: height + chromeInsets.top + chromeInsets.bottom
        )
        return clamp(frame, into: visibleFrame)
    }

    /// Deterministic cascade so new windows never exactly overlap.
    public static func cascadedFrame(base: NSRect, index: Int, visibleFrame: NSRect) -> NSRect {
        let step: CGFloat = 26
        let offset = CGFloat(index % 8) * step
        var frame = base
        frame.origin.x += offset
        frame.origin.y -= offset
        return clamp(frame, into: visibleFrame)
    }

    /// Centered default size clamped into the visible frame.
    public static func defaultFrame(size: CGSize, visibleFrame: NSRect) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width, height: height
        )
        return clamp(frame, into: visibleFrame)
    }
}
