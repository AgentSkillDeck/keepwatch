import Foundation

/// Free disk space and the usual places it goes. Read-only: Keepwatch shows
/// sizes and opens folders in Finder; it never deletes anything.
public enum DiskSpace {
    public struct Usage: Equatable, Sendable {
        public var available: Int64
        public var total: Int64
        public var usedFraction: Double { total > 0 ? min(1, max(0, Double(total - available) / Double(total))) : 0 }
    }

    /// Space macOS would make available for important use (it counts purgeable space).
    public static func usage(of url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Usage? {
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return Usage(available: free, total: Int64(total))
    }

    public static let thresholdChoicesGB = [5, 10, 20, 50]

    /// Warn when below the threshold, at most once a day.
    public static func shouldWarn(available: Int64, thresholdGB: Int, lastWarned: Date?, now: Date) -> Bool {
        guard thresholdGB > 0, available < Int64(thresholdGB) * 1_000_000_000 else { return false }
        guard let lastWarned else { return true }
        return now.timeIntervalSince(lastWarned) >= 86_400 || lastWarned > now
    }

    public struct Spot: Equatable, Identifiable, Sendable {
        public var name: String
        public var url: URL
        public var bytes: Int64
        public var id: String { url.path }
    }

    /// Folders that often grow large, under the home folder. Downloads, the
    /// Trash and other apps' containers are left out: macOS guards them, and
    /// reading them would make it ask for permission.
    public static func candidateFolders(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [(String, URL)] {
        [
            ("App caches", "Library/Caches"),
            ("Xcode build files", "Library/Developer/Xcode/DerivedData"),
            ("Xcode archives", "Library/Developer/Xcode/Archives"),
            ("iPhone support files", "Library/Developer/Xcode/iOS DeviceSupport"),
            ("Simulators", "Library/Developer/CoreSimulator"),
            ("Developer caches (~/.cache)", ".cache"), ("npm cache", ".npm"),
            ("Logs", "Library/Logs"),
        ].map { ($0.0, home.appendingPathComponent($0.1)) }
    }

    /// Total size of a folder's files, giving up after `maxFiles` files or
    /// when `deadline` passes (then the size is a lower bound).
    public static func folderSize(_ url: URL, maxFiles: Int = 400_000, deadline: Date = .distantFuture) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let file as URL in e {
            count += 1
            if count > maxFiles || (count % 2_000 == 0 && Date() > deadline) { break }
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.totalFileAllocatedSize else { continue }
            total &+= Int64(size)
        }
        return total
    }

    /// Sizes of the candidate folders that exist, largest first.
    public static func spots(home: URL = URL(fileURLWithPath: NSHomeDirectory()), secondsEach: TimeInterval = 4) -> [Spot] {
        candidateFolders(home: home).compactMap { name, url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Spot(name: name, url: url, bytes: folderSize(url, deadline: Date().addingTimeInterval(secondsEach)))
        }
        .filter { $0.bytes > 0 }
        .sorted { $0.bytes > $1.bytes }
    }
}
