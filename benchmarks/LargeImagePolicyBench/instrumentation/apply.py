#!/usr/bin/env python3
"""Applies the E4 instrumentation to an exported source tree.

Replacing whole files (the previous approach) silently reverts production changes
whenever the app moves on: an outdated copy of the decoder would be overlaid on a
newer tree and the run would measure the old path without saying so. This script
instead inserts the marks into whatever is there and asserts every anchor, so a
production change that invalidates an anchor fails loudly.

Usage: apply.py <tree-root>
"""
import os
import shutil
import sys

TREE = sys.argv[1] if len(sys.argv) > 1 else "."
SRC = os.path.join(TREE, "PicViewMac")


def edit(rel, replacements):
    path = os.path.join(SRC, rel)
    with open(path) as handle:
        text = handle.read()
    for old, new, tag in replacements:
        if old not in text:
            sys.exit(f"apply.py: anchor missing in {rel}: {tag!r}\n"
                     f"  the production code changed; update instrumentation/apply.py")
        text = text.replace(old, new, 1)
        print(f"  {rel}: {tag}")
    with open(path, "w") as handle:
        handle.write(text)


# The trace facility itself, copied in wholesale (it is not part of the app).
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "BenchTrace.swift"),
            os.path.join(SRC, "App/BenchTrace.swift"))
print("  App/BenchTrace.swift: copied")

edit("Imaging/ImageIODecoder.swift", [
    ('''            let descriptor = try Self.descriptor(for: source, url: url)''',
     '''            await BenchTrace.mark("T1 CGImageSourceCreateWithURL ...")
            let descriptor = try Self.descriptor(for: source, url: url)
            await BenchTrace.mark("T2 descriptor done")''', "T1/T2 marks"),
    ('''            guard let image = decodeOriented(source: source, index: index) else { return nil }
            return (BitmapMaterializer.materialize(image), .native)''',
     '''            BenchTrace.markFromAnyThread("decodeLimited: native path (long edge \\(longEdge))")
            guard let image = decodeOriented(source: source, index: index) else { return nil }
            let materialized = BitmapMaterializer.materialize(image)
            BenchTrace.noteTraversal("main native decode(materialized)")
            return (materialized, .native)''', "native decode marks"),
    ('''        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        return (thumbnail, .bucket(bucket))''',
     '''        BenchTrace.markFromAnyThread("decodeLimited: bounded path long edge \\(longEdge) bucket \\(bucket)")
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        BenchTrace.noteTraversal("main bounded decode(maxPx:\\(bucket))")
        return (thumbnail, .bucket(bucket))''', "bounded decode marks"),
])

edit("Imaging/ThumbnailPipeline.swift", [
    ('''    public func thumbnail(for url: URL, maxPixelSize: Int) async throws -> CGImage {''',
     '''    public func thumbnail(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        BenchTrace.markFromAnyThread("ThumbnailPipeline.thumbnail(maxPixelSize: \\(maxPixelSize)) START")
        BenchTrace.noteTraversal("drawer file thumbnail(maxPx:\\(maxPixelSize))")
        defer { BenchTrace.markFromAnyThread("ThumbnailPipeline.thumbnail(\\(maxPixelSize)) END") }''',
     "thumbnail marks"),
    ('''        ThumbnailPipelineMetrics.notePreview()''',
     '''        ThumbnailPipelineMetrics.notePreview()
        BenchTrace.markFromAnyThread("ThumbnailPipeline.preview(from: \\(image.width)x\\(image.height), maxPixelSize: \\(maxPixelSize))")
        if max(image.width, image.height) > DecodeBudget.maximumLongEdge {
            BenchTrace.noteTraversal("preview(oversized:\\(image.width)x\\(image.height))")
        }''', "preview marks"),
])

edit("Viewer/ImageCanvasView.swift", [
    ('''    public override func draw(_ dirtyRect: NSRect) {''',
     '''    public override func draw(_ dirtyRect: NSRect) {
        let benchT0 = benchNow()
        let benchHadImage = renderImage != nil
        BenchTrace.markFromAnyThread(String(format: "canvas draw ENTER image=%@ zoom=%.4f bounds=%.0fx%.0f metal=%@",
                                           benchHadImage ? "yes" : "nil", viewport.zoomScale,
                                           bounds.width, bounds.height,
                                           isUsingMetalForCurrentImage ? "yes" : "no"))
        defer {
            BenchTrace.noteDraw(duration: benchNow() - benchT0, dirty: dirtyRect,
                                bounds: bounds, hasImage: benchHadImage)
        }''', "draw marks"),
    ('''        guard let renderImage else { return }''',
     '''        guard let renderImage else { return }
        if max(renderImage.bitmap.width, renderImage.bitmap.height) > DecodeBudget.maximumLongEdge {
            // Tripwire: an oversized bitmap reaching the Quartz rasterizer is the original bug.
            BenchTrace.noteTraversal("canvas rasterization(oversized:\\(renderImage.bitmap.width)x\\(renderImage.bitmap.height))")
        }''', "oversized tripwire"),
])

edit("Viewer/ViewerState.swift", [
    ('''        playback = head.descriptor.animated ? .playing : .staticImage''',
     '''        playback = head.descriptor.animated ? .playing : .staticImage
        BenchTrace.mark("T5 ViewerState.apply(head:) — image published to UI")''', "T5 mark"),
    ('''    public func apply(frame: DecodedFrame) {''',
     '''    public func apply(frame: DecodedFrame) {
        BenchTrace.noteAppliedFrame()''', "applied-frame counter"),
])

# Temporary call-site counters: they answer "who drives the per-frame image loads?"
# without touching production code.
edit("Viewer/ViewerViewController.swift", [
    ("""    private func loadCurrentImage() {""",
     """    private func loadCurrentImage() {
        BenchTrace.markFromAnyThread("CALLER loadCurrentImage")""", "loadCurrentImage counter"),
])

edit("Imaging/DecodeCoordinator.swift", [
    ("""        let pageIndex = target.pageIndex""",
     """        BenchTrace.markFromAnyThread("CALLER coordinator.show")
        let pageIndex = target.pageIndex""", "show counter"),
    ("""        guard let head = try? await decoder.decodeFirstDisplayableFrame(url, target: target) else { return }""",
     """        BenchTrace.markFromAnyThread("CALLER preload")
        guard let head = try? await decoder.decodeFirstDisplayableFrame(url, target: target) else { return }""",
     "preload counter"),
])

edit("App/AppDelegate.swift", [
    ('''        if let path = SelfTest.requestedFilePath {''',
     '''        if let benchPath = ProcessInfo.processInfo.environment["PICLIGHT_TTI_BENCH"], !benchPath.isEmpty {
            // Same path Finder uses: FileOpenCoordinator -> FolderSession -> decode.
            BenchTrace.beginSummaryLoop()
            BenchTrace.startHeartbeat()
            BenchTrace.scheduleResizeSequence()
            BenchTrace.scheduleZoomProbe()
            BenchTrace.mark("T0 user open requested (FileOpenCoordinator.open)")
            BenchTrace.energyStart = BenchTrace.readEnergyNJ()
            environment.fileOpener.open(url: URL(fileURLWithPath: benchPath))
            return
        }

        if let path = SelfTest.requestedFilePath {''', "bench launch mode"),
])

print("apply.py: instrumentation applied")
