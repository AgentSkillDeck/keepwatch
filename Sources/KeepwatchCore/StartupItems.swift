import Foundation

/// Launch agents and daemons: programs that start by themselves at login or
/// boot. Malware and forgotten tools hide here, so Keepwatch lists them and
/// says when a new one appears. Reading only; removal is the user's choice.
public struct StartupItem: Equatable, Identifiable, Sendable {
    public enum Domain: String, Sendable {
        case user = "You"
        case allUsers = "All users"
        case system = "System (root)"
    }
    public var label: String
    public var program: String?
    public var path: String
    public var domain: Domain
    public var runAtLoad: Bool
    public var id: String { path }

    /// Plain name: the program's file name, else the label.
    public var name: String {
        program.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? label
    }
    public var isApple: Bool { label.hasPrefix("com.apple.") }
}

public enum StartupItems {
    static let maxFiles = 1_000
    static let maxPlistBytes = 256 * 1024

    public static func defaultFolders(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [(URL, StartupItem.Domain)] {
        [
            (home.appendingPathComponent("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .allUsers),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system),
        ]
    }

    public static func scan(_ folders: [(URL, StartupItem.Domain)] = defaultFolders()) -> [StartupItem] {
        var items: [StartupItem] = []
        for (dir, domain) in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files.prefix(maxFiles) where file.pathExtension == "plist" {
                items.append(read(file, domain: domain))
            }
        }
        return items.sorted { ($0.domain.rawValue, $0.name.lowercased()) < ($1.domain.rawValue, $1.name.lowercased()) }
    }

    /// Reads one plist leniently: a damaged or huge file still lists, by file name.
    static func read(_ file: URL, domain: StartupItem.Domain) -> StartupItem {
        let fallback = file.deletingPathExtension().lastPathComponent
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        guard let size, size <= maxPlistBytes, let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return StartupItem(label: fallback, program: nil, path: file.path, domain: domain, runAtLoad: false)
        }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        return StartupItem(label: (plist["Label"] as? String) ?? fallback, program: program, path: file.path,
                           domain: domain, runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false)
    }

    /// Items not in `seen` (by path). The first scan sees everything as known.
    public static func newItems(_ items: [StartupItem], seen: Set<String>?) -> [StartupItem] {
        guard let seen else { return [] }
        return items.filter { !seen.contains($0.path) }
    }
}
