import Foundation
import Security

enum FolderAccessStatus: String, Sendable {
    case checking, available, unavailable, needsSelection

    var title: String {
        switch self {
        case .checking: return "正在检查"
        case .available: return "可访问"
        case .unavailable: return "位置不可用"
        case .needsSelection: return "需要重新选择"
        }
    }
}

struct FolderAccessRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var path: String
    var bookmark: Data
    var securityScoped: Bool
    var status: FolderAccessStatus = .checking
    var detail: String = ""

    private enum CodingKeys: String, CodingKey { case id, path, bookmark, securityScoped }
}

struct ResolvedFolderBookmark: Sendable {
    let url: URL
    let stale: Bool
}

protocol FolderBookmarkProviding: Sendable {
    func create(for url: URL, securityScoped: Bool) throws -> Data
    func resolve(_ data: Data, securityScoped: Bool) throws -> ResolvedFolderBookmark
    func startAccess(_ url: URL) -> Bool
    func stopAccess(_ url: URL)
    func checkReadable(_ url: URL) throws
}

struct SystemFolderBookmarks: FolderBookmarkProviding {
    func create(for url: URL, securityScoped: Bool) throws -> Data {
        try url.bookmarkData(options: securityScoped ? [.withSecurityScope] : [],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ data: Data, securityScoped: Bool) throws -> ResolvedFolderBookmark {
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        if securityScoped { options.insert(.withSecurityScope) }
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return ResolvedFolderBookmark(url: url, stale: stale)
    }

    func startAccess(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccess(_ url: URL) { url.stopAccessingSecurityScopedResource() }

    func checkReadable(_ url: URL) throws {
        // Opening the directory checks real access without enumerating a huge image collection.
        guard let directory = opendir(url.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        closedir(directory)
    }

    static var isSandboxed: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
                as? Bool) == true
    }
}

/// Shared by the record and any operation already using it. Removing a record drops the store's
/// ownership; the last in-flight operation releases its own reference on completion.
final class FolderAccessScope: @unchecked Sendable {
    let url: URL
    private let backend: any FolderBookmarkProviding
    private let started: Bool

    init(url: URL, backend: any FolderBookmarkProviding, securityScoped: Bool) {
        self.url = url
        self.backend = backend
        started = securityScoped && backend.startAccess(url)
    }

    deinit { if started { backend.stopAccess(url) } }
}

struct FolderReadFailure: Sendable {
    let directory: URL
    let message: String
    let isPermission: Bool

    init(directory: URL, error: Error) {
        self.directory = directory
        isPermission = Self.isPermissionError(error as NSError)
        message = "无法读取文件夹“\(directory.lastPathComponent)”：\(error.localizedDescription)"
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }
}

@MainActor
final class FolderAccessStore {
    static let shared = FolderAccessStore()
    static let didChangeNotification = Notification.Name("com.piclight.folder-access.changed")
    private static let storageKey = "folderAccessRecords.v1"
    private struct StoredRecords: Codable { let version: Int; let records: [FolderAccessRecord] }

    private let defaults: UserDefaults
    private let backend: any FolderBookmarkProviding
    private let sandboxed: Bool
    private var scopes: [UUID: FolderAccessScope] = [:]
    private var refreshTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var restored = false
    private(set) var records: [FolderAccessRecord] = []
    private(set) var storageError: String?

    init(defaults: UserDefaults = .standard, backend: any FolderBookmarkProviding = SystemFolderBookmarks(),
         sandboxed: Bool = SystemFolderBookmarks.isSandboxed) {
        self.defaults = defaults
        self.backend = backend
        self.sandboxed = sandboxed
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        if let saved = try? JSONDecoder().decode(StoredRecords.self, from: data), saved.version == 1 {
            records = saved.records
        } else { storageError = "无法恢复保存的文件夹列表，请重新选择需要访问的文件夹。" }
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let generation = revision
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshRecords(generation: generation)
        }
        await refreshTask?.value
        if revision == generation { refreshTask = nil; restored = true }
    }

    private func refreshRecords(generation: UInt64) async {
        var recovered: [(URL, URL?)] = []
        for saved in records {
            guard revision == generation, !Task.isCancelled else { return }
            var record = saved
            do {
                if sandboxed && !record.securityScoped { throw CocoaError(.fileReadNoPermission) }
                let resolved = try backend.resolve(record.bookmark, securityScoped: record.securityScoped)
                let scope = scopes[record.id].flatMap { $0.url == resolved.url ? $0 : nil }
                    ?? FolderAccessScope(url: resolved.url, backend: backend, securityScoped: record.securityScoped)
                try await probe(scope.url)
                guard revision == generation, !Task.isCancelled else { return }
                if resolved.stale { record.bookmark = try backend.create(for: resolved.url, securityScoped: record.securityScoped) }
                record.path = Self.canonicalPath(resolved.url)
                record.status = .available
                record.detail = ""
                scopes[record.id] = scope
                if record.path != saved.path {
                    recovered.append((resolved.url, URL(fileURLWithPath: saved.path)))
                } else if saved.status == .needsSelection || saved.status == .unavailable {
                    recovered.append((resolved.url, nil))
                }
            } catch {
                guard revision == generation else { return }
                scopes[record.id] = nil
                record.status = Self.status(for: error)
                record.detail = error.localizedDescription
            }
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { continue }
            records[index] = record
        }
        guard revision == generation else { return }
        // Two moved bookmarks can resolve to the same directory; keep one record and lease.
        var paths = Set<String>()
        records.removeAll { record in
            if paths.insert(record.path).inserted { return false }
            scopes[record.id] = nil
            return true
        }
        if storageError == nil { save() }
        notify()
        for (url, previous) in recovered { notify(grantedURL: url, previousURL: previous) }
    }

    @discardableResult
    func add(_ selectedURL: URL, replacing id: UUID? = nil) async throws -> FolderAccessRecord {
        let scope = FolderAccessScope(url: selectedURL, backend: backend, securityScoped: sandboxed)
        try await probe(selectedURL)
        try Task.checkCancellation()
        if let id, !records.contains(where: { $0.id == id }) { throw CancellationError() }
        let bookmark = try backend.create(for: selectedURL, securityScoped: sandboxed)
        let path = Self.canonicalPath(selectedURL)
        let previousURL = id.flatMap { id in records.first { $0.id == id }.map { URL(fileURLWithPath: $0.path) } }
        let duplicate = records.first { $0.path == path }
        let record = FolderAccessRecord(id: duplicate?.id ?? id ?? UUID(), path: path,
                                        bookmark: bookmark, securityScoped: sandboxed, status: .available)
        invalidateRefresh()
        if let id, id != record.id { records.removeAll { $0.id == id }; scopes[id] = nil }
        records.removeAll { $0.id == record.id }
        records.append(record)
        scopes[record.id] = scope
        storageError = nil
        save()
        notify(grantedURL: selectedURL, previousURL: previousURL)
        return record
    }

    func remove(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        invalidateRefresh()
        records.removeAll { $0.id == id }
        scopes[id] = nil
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                                        userInfo: ["removedURL": URL(fileURLWithPath: record.path)])
    }

    func prepareAccess(to directory: URL) async -> FolderAccessScope? {
        if !restored { await refresh() }
        return records.filter { Self.covers(URL(fileURLWithPath: $0.path), directory) }
            .sorted { $0.path.count > $1.path.count }.compactMap { scopes[$0.id] }.first
    }

    func shutdown() {
        invalidateRefresh()
        scopes.removeAll()
        restored = false
    }

    private func invalidateRefresh() {
        revision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func probe(_ url: URL) async throws {
        let backend = backend
        try await Task.detached(priority: .utility) { try backend.checkReadable(url) }.value
    }

    private func save() {
        if let data = try? JSONEncoder().encode(StoredRecords(version: 1, records: records)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func notify(grantedURL: URL? = nil, previousURL: URL? = nil) {
        var info: [String: URL] = [:]
        if let grantedURL { info["grantedURL"] = grantedURL }
        if let previousURL { info["previousURL"] = previousURL }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: info)
    }

    func noteReadableDirectory(_ directory: URL) {
        guard let index = records.firstIndex(where: { $0.path == Self.canonicalPath(directory) }),
              records[index].status != .available else { return }
        // A newly selected ancestor can restore the directory even though its own bookmark
        // previously failed. Report the successful read, not the old failed probe.
        invalidateRefresh()
        records[index].status = .available
        records[index].detail = ""
        notify()
    }

    func noteReadFailure(_ failure: FolderReadFailure) {
        guard let index = records.firstIndex(where: { $0.path == Self.canonicalPath(failure.directory) }) else { return }
        invalidateRefresh()
        // A directory listing can fail while the selected file remains readable. Keep the
        // existing lease until remove/reselect/refresh so its decoder can finish using it.
        records[index].status = failure.isPermission ? .needsSelection : .unavailable
        records[index].detail = failure.message
        notify()
    }

    private static func status(for error: Error) -> FolderAccessStatus {
        let e = error as NSError
        if (e.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(e.code))
            || (e.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue,
                                                  CocoaError.fileReadNoSuchFile.rawValue].contains(e.code)) {
            return .unavailable
        }
        return .needsSelection
    }

    static func canonicalPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    static func covers(_ parent: URL, _ child: URL) -> Bool {
        let p = canonicalPath(parent), c = canonicalPath(child)
        return p == c || c.hasPrefix(p == "/" ? "/" : p + "/")
    }
}
