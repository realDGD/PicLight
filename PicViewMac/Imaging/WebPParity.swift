import Foundation
import CoreGraphics

/// Evidence for the "system ImageIO first" decision for animated WebP. It records
/// exactly what the current platform's ImageIO reports so the build can decide
/// whether a libwebp-backed decoder is needed at all.
public struct WebPParityReport: Sendable {
    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public let checks: [Check]

    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failures: [Check] { checks.filter { !$0.passed } }

    public var summary: String {
        checks.map { "\($0.passed ? "PASS" : "FAIL") \($0.name): \($0.detail)" }
            .joined(separator: "\n")
    }
}

public enum WebPParity {
    public struct Expectation: Sendable {
        public let fileName: String
        public let frameCount: Int
        public let pixelSize: CGSize
        public let durations: [TimeInterval]
        public let loopCount: Int?
    }

    /// Runs the animated-WebP fixture matrix against a decoder.
    public static func evaluate(decoder: ImageDecoding, directory: URL,
                                expectations: [Expectation]) async -> WebPParityReport {
        var checks: [WebPParityReport.Check] = []
        for expectation in expectations {
            let url = directory.appendingPathComponent(expectation.fileName)
            do {
                let descriptor = try await decoder.inspect(url)
                checks.append(.init(name: "\(expectation.fileName) frame count",
                                    passed: descriptor.frameCount == expectation.frameCount,
                                    detail: "expected \(expectation.frameCount), got \(descriptor.frameCount)"))
                checks.append(.init(name: "\(expectation.fileName) canvas size",
                                    passed: descriptor.pixelSize == expectation.pixelSize,
                                    detail: "expected \(expectation.pixelSize), got \(descriptor.pixelSize)"))
                checks.append(.init(name: "\(expectation.fileName) animated flag",
                                    passed: descriptor.animated == (expectation.frameCount > 1),
                                    detail: "animated=\(descriptor.animated)"))
                checks.append(.init(name: "\(expectation.fileName) loop count",
                                    passed: descriptor.loopCount == expectation.loopCount,
                                    detail: "expected \(String(describing: expectation.loopCount)), got \(String(describing: descriptor.loopCount))"))
                let matchesDurations = descriptor.frameDurations.count == expectation.durations.count
                    && zip(descriptor.frameDurations, expectation.durations)
                        .allSatisfy { abs($0 - $1) < 0.05 }
                checks.append(.init(name: "\(expectation.fileName) frame durations",
                                    passed: matchesDurations,
                                    detail: "expected \(expectation.durations), got \(descriptor.frameDurations)"))

                let head = try await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution)
                checks.append(.init(name: "\(expectation.fileName) first frame decodes",
                                    passed: head.image.width > 0 && head.image.height > 0,
                                    detail: "\(head.image.width)x\(head.image.height)"))

                var streamed = 0
                for try await _ in decoder.decodeRemainingFrames(url, descriptor: descriptor) {
                    streamed += 1
                }
                checks.append(.init(name: "\(expectation.fileName) remaining frames stream",
                                    passed: streamed == max(expectation.frameCount - 1, 0),
                                    detail: "expected \(max(expectation.frameCount - 1, 0)), got \(streamed)"))
            } catch {
                checks.append(.init(name: "\(expectation.fileName) inspect",
                                    passed: false, detail: "threw \(error)"))
            }
        }
        return WebPParityReport(checks: checks)
    }
}
