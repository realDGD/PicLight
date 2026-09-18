import CoreGraphics
import Foundation

/// Which gallery layout the folder browser is using.
public enum GalleryLayoutKind: String, CaseIterable, Codable, Sendable {
    /// Layout A: a regular grid of identical slots, each thumbnail aspect-fitted inside its slot.
    case uniformGrid
    /// Layout B: rows whose height is uniform but whose items are as wide as their aspect asks for,
    /// so a wide image is a wide item and a tall one is a tall item.
    case adaptiveGrid

    public var localizedName: String {
        switch self {
        case .uniformGrid: return "规则网格"
        case .adaptiveGrid: return "自适应网格"
        }
    }
}

/// One gallery cell's resolved geometry.
public struct GalleryCellFrame: Equatable, Sendable {
    /// Index into the gallery's item array.
    public let index: Int
    /// The whole item: image area plus the filename slot.
    public let frame: CGRect
    /// The image area inside `frame`, already aspect-fitted to the source.
    public let imageFrame: CGRect

    public init(index: Int, frame: CGRect, imageFrame: CGRect) {
        self.index = index
        self.frame = frame
        self.imageFrame = imageFrame
    }
}

/// A row of cells. Both layouts are row-based, which is what makes them virtualizable: a
/// collection view can create only the rows intersecting the visible rectangle, and a row's
/// geometry is a pure function of the item aspects and the container width.
public struct GalleryRow: Equatable, Sendable {
    public let cells: [GalleryCellFrame]
    /// The row's own rect in the layout's coordinate space.
    public let frame: CGRect

    public init(cells: [GalleryCellFrame], frame: CGRect) {
        self.cells = cells
        self.frame = frame
    }
}

/// The gallery's geometry, as pure functions.
///
/// Nothing here knows about views, and that is deliberate: the two layouts, the thumbnail-size
/// slider's effect and the "does a wide image get a wide item" question are all answerable without
/// rendering anything, which is what the tests do.
public enum GalleryLayout {
    /// The slider's range and default, from the spec.
    public static let minimumThumbnailSize: CGFloat = 80
    public static let maximumThumbnailSize: CGFloat = 320
    public static let defaultThumbnailSize: CGFloat = 160
    /// Vertical gap between rows, and horizontal gap between items in a row.
    public static let rowSpacing: CGFloat = 12
    public static let itemSpacing: CGFloat = 12
    /// The filename slot under each thumbnail. Always present: the gallery is for identifying
    /// files, and a grid of unlabelled pictures does not do that.
    public static let filenameSlotHeight: CGFloat = 16
    /// Outer margin around the grid.
    public static let contentInset: CGFloat = 16
    /// In the adaptive layout, an item's width is at least this and at most this, so one extremely
    /// wide image cannot take a whole row on its own and one extremely tall image cannot become a
    /// sliver.
    public static let adaptiveMinimumItemWidth: CGFloat = 60
    public static let adaptiveMaximumItemWidth: CGFloat = 640

    /// Clamps a slider value into the supported range.
    public static func clampThumbnailSize(_ size: CGFloat) -> CGFloat {
        min(max(size, minimumThumbnailSize), maximumThumbnailSize)
    }

    /// How much the slider must move before the grid is reflowed again.
    ///
    /// The grid's geometry is cheap, but the *decode* it implies is not, so the reflow is stepped:
    /// the slider is continuous and the layout follows it, while a sharper thumbnail is only
    /// requested when the drag settles (`GallerySliderThrottle`). A single point of travel changes
    /// nothing a person can see.
    public static let thumbnailSizeStep: CGFloat = 1

    /// Layout A: identical slots of `slot × slot` for the image, with the filename slot under it,
    /// packed into as many columns as fit.
    ///
    /// `aspects` is the source aspect (width ÷ height) per item; it decides the *fitted* rect
    /// inside the slot and never the slot itself, which is the whole point of a uniform grid.
    public static func uniformRows(aspects: [CGFloat], containerWidth: CGFloat,
                                   thumbnailSize: CGFloat) -> [GalleryRow] {
        let usable = containerWidth - 2 * contentInset
        let slot = clampThumbnailSize(thumbnailSize)
        guard usable >= slot, !aspects.isEmpty else { return [] }
        let columns = max(1, Int((usable + itemSpacing) / (slot + itemSpacing)))
        let rows = Int(ceil(Double(aspects.count) / Double(columns)))
        var result: [GalleryRow] = []
        result.reserveCapacity(rows)

        for row in 0..<rows {
            var cells: [GalleryCellFrame] = []
            let firstIndex = row * columns
            let lastIndex = min(firstIndex + columns, aspects.count) - 1
            let originY = contentInset + CGFloat(row) * (slot + filenameSlotHeight + rowSpacing)
            // Centre the row's items so a short final row still lines up with the ones above it
            // rather than hugging the left edge.
            let itemsInRow = lastIndex - firstIndex + 1
            let rowWidth = CGFloat(itemsInRow) * slot + CGFloat(itemsInRow - 1) * itemSpacing
            let startX = contentInset + max(0, (usable - rowWidth) / 2)

            for index in firstIndex...lastIndex {
                let rect = CGRect(x: startX + CGFloat(index - firstIndex) * (slot + itemSpacing),
                                  y: originY,
                                  width: slot, height: slot + filenameSlotHeight)
                cells.append(GalleryCellFrame(index: index,
                                              frame: rect,
                                              imageFrame: fittedRect(aspect: aspects[index],
                                                                     in: CGRect(x: rect.minX,
                                                                                y: rect.minY,
                                                                                width: slot,
                                                                                height: slot))))
            }
            result.append(GalleryRow(cells: cells,
                                     frame: CGRect(x: 0, y: originY, width: containerWidth,
                                                   height: slot + filenameSlotHeight)))
        }
        return result
    }

    /// Layout B: justified rows. Each row has one height; items are as wide as their aspect asks
    /// for within a per-item range, and the row is closed when the next item would not fit.
    ///
    /// This is *not* masonry: rows are full-width and aligned, items do not interlock vertically,
    /// and the layout is a pure function of the aspects and the width. A row's height comes from
    /// the declared thumbnail size, so the slider controls it exactly as in layout A.
    public static func adaptiveRows(aspects: [CGFloat], containerWidth: CGFloat,
                                    thumbnailSize: CGFloat) -> [GalleryRow] {
        let usable = containerWidth - 2 * contentInset
        let rowHeight = clampThumbnailSize(thumbnailSize)
        guard usable >= adaptiveMinimumItemWidth, !aspects.isEmpty, rowHeight > 0 else { return [] }

        var rows: [GalleryRow] = []
        var index = 0
        var originY = contentInset

        while index < aspects.count {
            // Collect the widest run of items whose widths fit the row.
            var widths: [CGFloat] = []
            var widthSum: CGFloat = 0
            var cursor = index
            while cursor < aspects.count {
                let width = itemWidth(aspect: aspects[cursor], rowHeight: rowHeight)
                let needed = widthSum + (widths.isEmpty ? 0 : itemSpacing) + width
                if !widths.isEmpty, needed > usable { break }
                widths.append(width)
                widthSum = needed
                cursor += 1
                if widthSum >= usable { break }
            }
            // A single item wider than the row is clamped rather than allowed to overflow.
            if widths.count == 1, widthSum > usable {
                widths[0] = usable
                widthSum = usable
                cursor = index + 1
            }

            var cells: [GalleryCellFrame] = []
            var x = contentInset
            for (offset, width) in widths.enumerated() {
                let itemIndex = index + offset
                let rect = CGRect(x: x, y: originY, width: width,
                                  height: rowHeight + filenameSlotHeight)
                cells.append(GalleryCellFrame(index: itemIndex,
                                              frame: rect,
                                              imageFrame: fittedRect(aspect: aspects[itemIndex],
                                                                     in: CGRect(x: x, y: originY,
                                                                                width: width,
                                                                                height: rowHeight))))
                x += width + itemSpacing
            }
            rows.append(GalleryRow(cells: cells,
                                   frame: CGRect(x: 0, y: originY, width: containerWidth,
                                                 height: rowHeight + filenameSlotHeight)))
            originY += rowHeight + filenameSlotHeight + rowSpacing
            index = cursor
            _ = cells
        }
        return rows
    }

    /// An adaptive item's width for a given row height: the aspect's own width, clamped so one
    /// extreme shape cannot dominate or vanish.
    public static func itemWidth(aspect: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let ideal = rowHeight * max(0.01, aspect)
        return min(max(ideal, adaptiveMinimumItemWidth), adaptiveMaximumItemWidth)
    }

    /// Dispatches to the chosen layout.
    public static func rows(for kind: GalleryLayoutKind, aspects: [CGFloat],
                            containerWidth: CGFloat, thumbnailSize: CGFloat) -> [GalleryRow] {
        switch kind {
        case .uniformGrid:
            return uniformRows(aspects: aspects, containerWidth: containerWidth,
                               thumbnailSize: thumbnailSize)
        case .adaptiveGrid:
            return adaptiveRows(aspects: aspects, containerWidth: containerWidth,
                                thumbnailSize: thumbnailSize)
        }
    }

    /// The total content size, which is what the collection view's scroll view needs.
    public static func contentHeight(of rows: [GalleryRow]) -> CGFloat {
        guard let last = rows.last else { return 2 * contentInset }
        return last.frame.maxY + contentInset
    }

    /// The aspect-fit rect of a source inside a slot, centred on both axes. The same rule the
    /// drawer's square slot uses, and the same reason: the slot is the layout's, the aspect only
    /// chooses a rect inside it.
    public static func fittedRect(aspect: CGFloat, in slot: CGRect) -> CGRect {
        guard aspect.isFinite, aspect > 0, slot.width > 0, slot.height > 0 else { return .zero }
        let slotAspect = slot.width / slot.height
        let widthLimited = aspect >= slotAspect
        let width = widthLimited ? slot.width : slot.height * aspect
        let height = widthLimited ? slot.width / aspect : slot.height
        return CGRect(x: slot.minX + (slot.width - width) / 2,
                      y: slot.minY + (slot.height - height) / 2,
                      width: width, height: height)
    }

    /// Which rows intersect a visible rectangle. This is the virtualization question — "which cells
    /// exist right now" — answered from the layout alone, so it can be tested without a scroll view.
    public static func visibleRows(in visibleRect: CGRect, of rows: [GalleryRow]) -> [GalleryRow] {
        rows.filter { $0.frame.intersects(visibleRect) }
    }

    /// How many cells a layout materializes for a visible rectangle. Used to prove that a
    /// ten-thousand-image folder does not create ten thousand cells.
    public static func visibleCellCount(in visibleRect: CGRect, of rows: [GalleryRow]) -> Int {
        visibleRows(in: visibleRect, of: rows).reduce(0) { $0 + $1.cells.count }
    }
}
