import XCTest
@testable import KeepwatchCore

final class UpdateInstallerTests: XCTestCase {
    let tag = "https://github.com/AgentSkillDeck/keepwatch/releases/tag/v0.3.0"
    let dl = "https://github.com/AgentSkillDeck/keepwatch/releases/download/v0.3.0/"

    func release(_ assets: [(String, String)]) -> UpdateCheck.Release? {
        let list = assets.map { "{\"name\":\"\($0.0)\",\"browser_download_url\":\"\($0.1)\"}" }.joined(separator: ",")
        return UpdateCheck.parse(Data("{\"tag_name\":\"v0.3.0\",\"html_url\":\"\(tag)\",\"assets\":[\(list)]}".utf8))
    }

    func testFindsOnlyThisReleasesDownloads() {
        let ok = release([("Keepwatch-0.3.0.zip", dl + "Keepwatch-0.3.0.zip"), ("SHA256SUMS.txt", dl + "SHA256SUMS.txt")])
        XCTAssertEqual(ok?.appZip?.absoluteString, dl + "Keepwatch-0.3.0.zip")
        XCTAssertEqual(ok?.checksums?.absoluteString, dl + "SHA256SUMS.txt")
        XCTAssertNil(release([("Keepwatch-0.3.0.zip", "https://evil.example/Keepwatch-0.3.0.zip")])?.appZip)
        XCTAssertNil(release([("Keepwatch-0.3.0.zip", "https://github.com/someone/else/releases/download/v0.3.0/Keepwatch-0.3.0.zip")])?.appZip)
        XCTAssertNil(release([("Keepwatch-0.3.0.zip", "https://github.com/AgentSkillDeck/keepwatch/releases/download/v0.2.0/Keepwatch-0.3.0.zip")])?.appZip,
                     "a download from another version")
        XCTAssertNil(release([("Keepwatch-0.2.0.zip", dl + "Keepwatch-0.2.0.zip")])?.appZip, "wrong file name")
        XCTAssertNotNil(release([]), "no assets: still offered, but only as a page link")
    }

    func testChecksumLines() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let text = "\(a)  Keepwatch-0.3.0.dmg\n\(b)  Keepwatch-0.3.0.zip\n"
        XCTAssertEqual(UpdateInstaller.checksum(for: "Keepwatch-0.3.0.zip", in: text), b.lowercased())
        XCTAssertNil(UpdateInstaller.checksum(for: "Keepwatch-0.4.0.zip", in: text))
        XCTAssertNil(UpdateInstaller.checksum(for: "x.zip", in: "abc  x.zip"), "not a SHA-256")
        XCTAssertNil(UpdateInstaller.checksum(for: "x.zip", in: "\(a)  x.zip extra"))
    }

    func testRedirectsStayOnGitHub() {
        XCTAssertTrue(GitHubOnlyRedirects.allowed(URL(string: "https://release-assets.githubusercontent.com/x")))
        XCTAssertTrue(GitHubOnlyRedirects.allowed(URL(string: "https://objects.githubusercontent.com/x")))
        XCTAssertFalse(GitHubOnlyRedirects.allowed(URL(string: "http://objects.githubusercontent.com/x")))
        XCTAssertFalse(GitHubOnlyRedirects.allowed(URL(string: "https://githubusercontent.com.evil.example/x")))
    }

    func makeApp(version: String, in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Keepwatch.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": UpdateInstaller.bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kwu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testVerifyNeedsSignatureNotarizationAndTheOfferedNewerVersion() throws {
        let app = try makeApp(version: "0.3.0", in: try tempDir())
        let yes: (URL) -> Bool = { _ in true }, no: (URL) -> Bool = { _ in false }
        XCTAssertNil(UpdateInstaller.verify(app: app, offered: "0.3.0", current: "0.2.0", signed: yes, notarized: yes))
        XCTAssertEqual(UpdateInstaller.verify(app: app, offered: "0.3.0", current: "0.2.0", signed: no, notarized: yes), .signature)
        XCTAssertEqual(UpdateInstaller.verify(app: app, offered: "0.3.0", current: "0.2.0", signed: yes, notarized: no), .notarization)
        XCTAssertEqual(UpdateInstaller.verify(app: app, offered: "0.4.0", current: "0.2.0", signed: yes, notarized: yes), .version)
        XCTAssertEqual(UpdateInstaller.verify(app: app, offered: "0.3.0", current: "0.3.0", signed: yes, notarized: yes), .version,
                       "never reinstall or downgrade")
    }

    func testUnsignedAppIsRejected() throws {
        let app = try makeApp(version: "0.3.0", in: try tempDir())
        XCTAssertFalse(UpdateInstaller.hasOurSignature(app))
    }

    /// The installed release build is signed by the team, so it must pass.
    func testInstalledReleasePassesSignatureCheck() throws {
        let installed = URL(fileURLWithPath: "/Applications/Keepwatch.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: installed.path), "Keepwatch isn't installed")
        XCTAssertTrue(UpdateInstaller.hasOurSignature(installed))
        XCTAssertFalse(UpdateInstaller.hasOurSignature(installed, teamID: "AAAAAAAAAA"), "another team's app")
    }

    func testReplaceSwapsTheAppAndKeepsTheOldOneOnFailure() throws {
        let dir = try tempDir()
        let installedDir = dir.appendingPathComponent("Applications")
        let newDir = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let installed = try makeApp(version: "0.2.0", in: installedDir)
        let new = try makeApp(version: "0.3.0", in: newDir)
        XCTAssertNil(UpdateInstaller.replace(installed: installed, with: new))
        XCTAssertEqual(UpdateInstaller.version(ofApp: installed), "0.3.0")

        let missing = newDir.appendingPathComponent("gone.app")
        XCTAssertNotNil(UpdateInstaller.replace(installed: installed, with: missing))
        XCTAssertEqual(UpdateInstaller.version(ofApp: installed), "0.3.0", "a failed update leaves the app alone")
    }

    /// The real thing, against the published v0.2.0 release: download,
    /// checksum, signature, notarization, swap. Needs the network, so opt-in.
    func testInstallsAPublishedReleaseOverACopy() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEEPWATCH_NETWORK_TESTS"] == "1", "set KEEPWATCH_NETWORK_TESTS=1")
        let base = "https://github.com/AgentSkillDeck/keepwatch/releases/download/v0.2.0/"
        let release = UpdateCheck.Release(version: "0.2.0", page: URL(string: base)!,
                                          appZip: URL(string: base + "Keepwatch-0.2.0.zip"),
                                          checksums: URL(string: base + "SHA256SUMS.txt"))
        let installed = try makeApp(version: "0.1.0", in: try tempDir())
        let failure = await UpdateInstaller.install(release, over: installed, current: "0.1.0")
        XCTAssertNil(failure)
        XCTAssertEqual(UpdateInstaller.version(ofApp: installed), "0.2.0")
        XCTAssertTrue(UpdateInstaller.hasOurSignature(installed))
        let tampered = UpdateCheck.Release(version: "0.2.0", page: release.page, appZip: URL(string: base + "Keepwatch-0.2.0.dmg"),
                                           checksums: release.checksums)
        let other = try makeApp(version: "0.1.0", in: try tempDir())
        let result = await UpdateInstaller.install(tampered, over: other, current: "0.1.0")
        XCTAssertNotNil(result, "a file that isn't the app zip is refused")
        XCTAssertEqual(UpdateInstaller.version(ofApp: other), "0.1.0")
    }
}
