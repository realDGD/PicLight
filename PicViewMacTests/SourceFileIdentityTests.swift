import XCTest
import AppKit
@testable import PicViewMac

/// `SourceFileIdentity`: what makes a file at a path a *particular* file.
///
/// The interface-level complement to `NativeInFlightReplacementTests`, which drives the scheduler
/// with replacements. These are the properties the identity itself has to have for that to work:
/// one `stat` per read, no file contents, and every field that a replacement can move.
@MainActor
final class SourceFileIdentityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piclight-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ byte: UInt8, to url: URL, length: Int = 4_096) throws {
        try Data(repeating: byte, count: length).write(to: url)
    }

    /// The documented fields are all present for a real file.
    func testTheIdentityCarriesTheFieldsAReplacementCanMove() throws {
        let file = Fixtures.url("oversized-detail.png")
        let identity = SourceFileIdentity.read(at: file)
        XCTAssertTrue(identity.exists)
        XCTAssertGreaterThan(identity.fileSize, 0)
        XCTAssertGreaterThan(identity.modificationTime, 0)
        XCTAssertGreaterThan(identity.changeTime, 0)
        XCTAssertNotNil(identity.inode, "the inode is what tells a replacement from a rewrite")
        XCTAssertNotNil(identity.volumeIdentifier, "and the volume id what tells a move from a copy")
        XCTAssertEqual(identity.path, file.path,
                       "the path is spelled the way the tile cache spells it")
        XCTAssertEqual(identity.canonicalPath, file.standardizedFileURL.path)
    }

    /// A file replaced by different bytes at the same length and date is still a different file.
    func testAReplacementThatRestoresSizeAndDateIsStillDetected() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("cunning.png")
        try write(0x44, to: file)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate],
                                              ofItemAtPath: file.path)
        let before = SourceFileIdentity.read(at: file)

        try write(0x55, to: file)
        try FileManager.default.setAttributes([.modificationDate: originalDate],
                                              ofItemAtPath: file.path)
        let after = SourceFileIdentity.read(at: file)

        XCTAssertNotEqual(before, after,
                          "same size, same date, different bytes: the identity must still move")
        XCTAssertNotEqual(before.versionToken, after.versionToken)
    }

    /// An ordinary save moves it too.
    func testANormalSaveMovesTheIdentity() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("photo.png")
        try write(0x11, to: file)
        let before = SourceFileIdentity.read(at: file)

        try write(0x22, to: file, length: 8_192)
        let after = SourceFileIdentity.read(at: file)
        XCTAssertNotEqual(before, after)
        XCTAssertNotEqual(before.fileSize, after.fileSize)
    }

    /// And an unchanged file keeps it, so a re-request stays warm.
    func testAnUnchangedFileKeepsItsIdentity() throws {
        let file = Fixtures.url("oversized-detail.png")
        XCTAssertEqual(SourceFileIdentity.read(at: file), SourceFileIdentity.read(at: file))
        XCTAssertEqual(SourceFileIdentity.read(at: file).versionToken,
                       SourceFileIdentity.read(at: file).versionToken)
    }

    /// A missing file has an identity that says so rather than throwing or inventing values.
    func testAMissingFileSaysSo() throws {
        let directory = try makeTemporaryDirectory()
        let identity = SourceFileIdentity.read(at: directory.appendingPathComponent("gone.png"))
        XCTAssertFalse(identity.exists)
        XCTAssertEqual(identity.fileSize, -1)
        XCTAssertNil(identity.inode)
        XCTAssertEqual(identity.versionToken, "missing")
    }

    /// The version token is what the cache compares, and it has to move with every field that
    /// describes the file's state: two identities differing in one field must not share a token.
    ///
    /// The path is deliberately not one of them — it is the cache map's key, so the question the
    /// token answers is "is the file *at this path* still the file the tiles were decoded from".
    func testTheVersionTokenMovesWithEveryFieldOfTheFile() {
        func identity(size: Int64 = 10, modified: TimeInterval = 100, changed: TimeInterval = 200,
                      inode: UInt64 = 5, volume: UInt64 = 7) -> SourceFileIdentity {
            SourceFileIdentity(path: "/tmp/a.png", canonicalPath: "/tmp/a.png", fileSize: size,
                               modificationTime: modified, changeTime: changed, inode: inode,
                               volumeIdentifier: volume, exists: true)
        }
        let base = identity()
        let variants: [(String, SourceFileIdentity)] = [
            ("size", identity(size: 11)),
            ("modification time", identity(modified: 101)),
            ("change time", identity(changed: 201)),
            ("inode", identity(inode: 6)),
            ("volume", identity(volume: 8)),
        ]
        for (field, variant) in variants {
            XCTAssertNotEqual(base.versionToken, variant.versionToken,
                              "a change of \(field) must move the version")
        }
        XCTAssertEqual(base.versionToken, identity().versionToken,
                       "and an unchanged file keeps it")
    }

    /// Two spellings of one file are one file. `/private/var/...` and `/var/...` are the same file
    /// to the file system (`/var` is a symlink), and the identity has to agree.
    func testTwoSpellingsOfOnePathReferToTheSameFile() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("photo.png")
        try write(0x11, to: file)
        let direct = SourceFileIdentity.read(at: file)
        let otherSpelling = URL(fileURLWithPath: "/private" + file.path)
        guard FileManager.default.fileExists(atPath: otherSpelling.path) else {
            throw XCTSkip("this volume is not reached through /private")
        }
        let indirect = SourceFileIdentity.read(at: otherSpelling)

        XCTAssertTrue(direct.refersToSameFile(as: indirect),
                      "the inode and the volume say this is one file, whatever the spelling")
        XCTAssertNotEqual(direct.path, indirect.path, "…and the spellings really are different")
    }

    /// Reading the identity must not read the file. A file whose *contents* are unreadable is still
    /// identified: `stat` does not open it.
    func testReadingTheIdentityDoesNotOpenTheFile() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("unreadable.png")
        try write(0x11, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: file.path)
        }
        let identity = SourceFileIdentity.read(at: file)
        XCTAssertTrue(identity.exists, "metadata is readable even when the contents are not")
        XCTAssertGreaterThan(identity.fileSize, 0)
    }
}
