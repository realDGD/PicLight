import AppKit
import UniformTypeIdentifiers

/// macOS associates content types, so aliases such as JPG/JPEG are one choice.
enum ImageFileFormat: String, CaseIterable, Sendable {
    case jpeg, png, gif, webp, tiff, bmp, ico

    var contentType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .gif: return .gif
        case .webp: return .webP
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .ico: return .ico
        }
    }

    var filenameExtensions: [String] {
        switch self {
        case .jpeg: return ["jpg", "jpeg"]
        case .tiff: return ["tif", "tiff"]
        default: return [rawValue]
        }
    }

    var displayName: String {
        "\(rawValue.uppercased())（\(filenameExtensions.map { "." + $0 }.joined(separator: "、"))）"
    }
}

@MainActor
protocol FileAssociationWorkspace {
    func defaultApplication(for contentType: UTType) -> URL?
    func setDefaultApplication(at applicationURL: URL, for contentType: UTType) async throws
}

@MainActor
private struct SystemFileAssociationWorkspace: FileAssociationWorkspace {
    func defaultApplication(for contentType: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: contentType)
    }

    func setDefaultApplication(at applicationURL: URL, for contentType: UTType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The system handles any consent prompt and calls back after the user's decision.
            NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: contentType) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

struct FileAssociationResult {
    struct Failure {
        let format: ImageFileFormat
        let message: String
    }

    var associated: [ImageFileFormat] = []
    var failures: [Failure] = []
}

@MainActor
final class FileAssociationService {
    private let workspace: any FileAssociationWorkspace
    private let applicationURL: URL?
    private(set) var isApplying = false

    convenience init() {
        let bundle = Bundle.main
        let isApplication = bundle.bundleURL.pathExtension.lowercased() == "app"
            && bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
        self.init(workspace: SystemFileAssociationWorkspace(),
                  applicationURL: isApplication ? bundle.bundleURL : nil)
    }

    init(workspace: any FileAssociationWorkspace, applicationURL: URL?) {
        self.workspace = workspace
        self.applicationURL = applicationURL
    }

    var canAssociate: Bool { applicationURL != nil }

    func currentApplication(for format: ImageFileFormat) -> URL? {
        workspace.defaultApplication(for: format.contentType)
    }

    func isAssociated(_ format: ImageFileFormat) -> Bool {
        guard let applicationURL, let current = currentApplication(for: format) else { return false }
        // Another installed copy must not be reported as this bundle: it may be on a mounted DMG.
        return current.resolvingSymlinksInPath().standardizedFileURL
            == applicationURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func associate(_ formats: Set<ImageFileFormat>) async throws -> FileAssociationResult {
        guard !isApplying else { throw AssociationError.alreadyApplying }
        guard !formats.isEmpty else { return FileAssociationResult() }
        guard let applicationURL else { throw AssociationError.requiresAppBundle }
        isApplying = true
        defer { isApplying = false }

        var result = FileAssociationResult()
        // Sequential requests keep system consent prompts from piling up.
        for format in ImageFileFormat.allCases where formats.contains(format) {
            if isAssociated(format) {
                result.associated.append(format)
                continue
            }
            do {
                try await workspace.setDefaultApplication(at: applicationURL, for: format.contentType)
                if isAssociated(format) {
                    result.associated.append(format)
                } else {
                    result.failures.append(.init(format: format,
                        message: "macOS 尚未将此格式的默认应用设为当前 PicLight，请刷新状态后重试。"))
                }
            } catch {
                result.failures.append(.init(format: format, message: error.localizedDescription))
            }
        }
        return result
    }

    private enum AssociationError: LocalizedError {
        case requiresAppBundle, alreadyApplying

        var errorDescription: String? {
            switch self {
            case .requiresAppBundle: return "请先将 PicLight.app 放到应用程序文件夹并启动，再设置格式关联。"
            case .alreadyApplying: return "正在设置格式关联，请等待完成。"
            }
        }
    }
}
