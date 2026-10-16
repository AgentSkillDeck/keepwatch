import CryptoKit
import Foundation
import Security

/// Installs a release the update check found, when the user clicks Install.
/// No third-party updater: it downloads `Keepwatch-<version>.zip` from this
/// repo's GitHub release, and only replaces the app if
/// - the zip's SHA-256 matches the release's `SHA256SUMS.txt`,
/// - the app inside is signed by the same Developer ID team and bundle id,
///   is notarized (Gatekeeper accepts it), and
/// - its version is the one offered and newer than the running one.
/// The old app goes to the Trash, so an update can be undone by hand.
public enum UpdateInstaller {
    public static let bundleID = "app.keepwatch.Keepwatch"
    public static let teamID = "S99G3X6RPM"
    static let maxZipBytes: Int64 = 80 * 1024 * 1024
    static let maxChecksumBytes = 64 * 1024

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noDownload, download, tooLarge, checksum, unpack, signature, notarization, version, install(String)

        public var description: String {
            switch self {
            case .noDownload: "This release has no app download."
            case .download: "The download didn't finish."
            case .tooLarge: "The download is larger than expected."
            case .checksum: "The download doesn't match the release's checksum."
            case .unpack: "The download couldn't be opened."
            case .signature: "The new app isn't signed by Keepwatch's developer."
            case .notarization: "macOS didn't accept the new app (not notarized)."
            case .version: "The new app's version isn't the one offered."
            case .install(let why): "Couldn't replace the app: \(why)"
            }
        }
    }

    /// The SHA-256 listed for `name` in a `SHA256SUMS.txt` (`<hex>  <name>` lines).
    static func checksum(for name: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1] == name || parts[1] == "*\(name)" else { continue }
            let hex = parts[0].lowercased()
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) { return hex }
        }
        return nil
    }

    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Is the app at `url` signed by our team with our bundle id? Checks every
    /// architecture and nested code, strictly.
    public static func hasOurSignature(_ url: URL, teamID: String = teamID, bundleID: String = bundleID) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Gatekeeper's verdict, which needs notarization for a downloaded app.
    static func gatekeeperAccepts(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        p.arguments = ["--assess", "--type", "execute", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func version(ofApp url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Checks an unpacked app before it may replace the running one.
    static func verify(app: URL, offered: String, current: String,
                       signed: (URL) -> Bool = { hasOurSignature($0) },
                       notarized: (URL) -> Bool = gatekeeperAccepts) -> Failure? {
        guard signed(app) else { return .signature }
        guard notarized(app) else { return .notarization }
        guard let v = version(ofApp: app), v == offered, UpdateCheck.isNewer(v, than: current) else { return .version }
        return nil
    }

    /// Puts `new` where `installed` is; the old app goes to the Trash (or is
    /// deleted if there is no Trash). Nothing is lost if moving `new` fails.
    static func replace(installed: URL, with new: URL, fm: FileManager = .default) -> Failure? {
        let parent = installed.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".Keepwatch-update-\(UUID().uuidString).app")
        do {
            try fm.moveItem(at: new, to: staged)
        } catch { return .install("no permission to write to \(parent.path)") }
        do {
            var trashed: NSURL?
            if (try? fm.trashItem(at: installed, resultingItemURL: &trashed)) == nil, fm.fileExists(atPath: installed.path) {
                try fm.removeItem(at: installed)
            }
            try fm.moveItem(at: staged, to: installed)
            return nil
        } catch {
            try? fm.removeItem(at: staged)
            return .install(error.localizedDescription)
        }
    }

    /// Downloads, checks and installs `release` over `installed`. Never
    /// touches the installed app unless every check passes.
    public static func install(_ release: UpdateCheck.Release, over installed: URL, current: String) async -> Failure? {
        guard let zipURL = release.appZip, let sumsURL = release.checksums else { return .noDownload }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("keepwatch-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) } catch { return .unpack }

        let session = URLSession(configuration: .ephemeral, delegate: GitHubOnlyRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (sums, sumsResponse) = try? await session.data(from: sumsURL),
              (sumsResponse as? HTTPURLResponse)?.statusCode == 200, sums.count <= maxChecksumBytes,
              let expected = checksum(for: zipURL.lastPathComponent, in: String(decoding: sums, as: UTF8.self))
        else { return .checksum }
        guard let (file, response) = try? await session.download(from: zipURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .download }
        let zip = work.appendingPathComponent("update.zip")
        guard (try? FileManager.default.moveItem(at: file, to: zip)) != nil else { return .download }
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? nil
        guard let size, size <= maxZipBytes else { return .tooLarge }
        guard sha256(of: zip) == expected else { return .checksum }

        let out = work.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, out.path]
        guard (try? ditto.run()) != nil else { return .unpack }
        ditto.waitUntilExit()
        let app = out.appendingPathComponent("Keepwatch.app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else { return .unpack }
        if let failure = verify(app: app, offered: release.version, current: current) { return failure }
        return replace(installed: installed, with: app)
    }
}

/// Follows redirects only to GitHub's own download hosts.
final class GitHubOnlyRedirects: NSObject, URLSessionTaskDelegate {
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host else { return false }
        return host == "github.com" || host == "objects.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Self.allowed(request.url) ? request : nil
    }
}
