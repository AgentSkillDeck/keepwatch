import Darwin
import Foundation

/// A TCP port some process of the current user is listening on.
public struct ListeningPort: Equatable, Hashable, Sendable {
    public var port: Int
    public var address: String
    public var pid: Int32
    public var process: String
    /// Part of macOS (runs from /System, /usr, /Library/Apple): never offer Stop.
    public var isSystem: Bool = false
}

/// "What's on :3000?": listening TCP ports from `lsof`. Without root, lsof
/// only reports the current user's processes, which is exactly what a
/// developer can stop anyway.
public enum ListeningPorts {
    public static func parse(_ output: String) -> [ListeningPort] {
        var result: Set<ListeningPort> = []
        var pid: Int32?
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""
            case "c": command = value
            case "n":
                // "*:3000", "127.0.0.1:9277", "[::1]:5432"
                guard let pid, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { continue }
                result.insert(ListeningPort(port: port, address: String(value[..<colon]), pid: pid, process: command))
            default: continue
            }
        }
        // One row per (port, pid): IPv4 and IPv6 listeners collapse together.
        var seen = Set<String>()
        return result.sorted { ($0.port, $0.pid, $0.address) < ($1.port, $1.pid, $1.address) }
            .filter { seen.insert("\($0.port)/\($0.pid)").inserted }
    }

    public static func current() -> [ListeningPort] {
        parse(SystemState.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 5) ?? "")
            .map { p in var p = p; p.isSystem = isSystemPath(executablePath(p.pid)); return p }
    }

    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    /// Unknown paths count as system: when in doubt, don't offer Stop.
    public static func isSystemPath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return true }
        return systemPrefixes.contains { path.hasPrefix($0) }
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Asks a process to quit (SIGTERM). Only processes we own can be signalled.
    @discardableResult
    public static func stop(pid: Int32) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return kill(pid, SIGTERM) == 0
    }
}
