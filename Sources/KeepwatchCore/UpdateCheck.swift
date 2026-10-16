import Foundation

/// The opt-in update check: Keepwatch's only network request (issue #4).
/// One GET to GitHub's "latest release" API; it never downloads or installs.
public enum UpdateCheck {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/AgentSkillDeck/keepwatch/releases/latest")
    /// Responses larger than this are ignored.
    static let maxResponseBytes = 256 * 1024
    /// Automatic checks run at most this often.
    public static let interval: TimeInterval = 86_400

    public struct Release: Equatable, Sendable {
        public var version: String
        public var page: URL
    }

    /// Reads `tag_name` and `html_url` from the API's JSON. The page must be on
    /// github.com, so a tampered response can't send the user elsewhere.
    public static func parse(_ data: Data) -> Release? {
        guard data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let html = object["html_url"] as? String, let page = URL(string: html),
              page.scheme == "https", page.host == "github.com",
              let version = normalized(tag) else { return nil }
        return Release(version: version, page: page)
    }

    /// "v0.3.0" → "0.3.0"; nil unless it is one to four dot-separated numbers.
    static func normalized(_ tag: String) -> String? {
        let t = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return t
    }

    /// True if `latest` is a higher version than `current`.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let a = normalized(latest), let b = normalized(current) else { return false }
        let x = a.split(separator: ".").compactMap { Int($0) }
        let y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Whether an automatic check is due.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    /// Fetches the latest release. Ephemeral session: no cookies, no cache.
    public static func fetchLatest() async -> Release? {
        guard let url = latestReleaseURL else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Keepwatch", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
