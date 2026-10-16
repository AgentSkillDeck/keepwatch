import Darwin
import Foundation

/// Finds the app a terminal process runs in (Terminal, iTerm, Warp, VS Code…)
/// by walking up its parent processes, so a click on "your agent is waiting"
/// can bring that window forward.
public enum HostApp {
    /// Parent chains deeper than this are cut off (and cycles can't loop).
    static let maxDepth = 24

    public static func parentPID(of pid: Int32) -> Int32? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let parent = Int32(bitPattern: bsd.pbi_ppid)
        return parent > 1 ? parent : nil
    }

    /// `pid`'s ancestors, nearest first, stopping before launchd.
    public static func ancestors(of pid: Int32, parent: (Int32) -> Int32? = parentPID(of:)) -> [Int32] {
        var chain: [Int32] = []
        var seen: Set<Int32> = [pid]
        var current = pid
        while chain.count < maxDepth, let next = parent(current), seen.insert(next).inserted {
            chain.append(next)
            current = next
        }
        return chain
    }

    /// The nearest ancestor that `isApp` accepts (a regular app with a window).
    public static func host(of pid: Int32, parent: (Int32) -> Int32? = parentPID(of:), isApp: (Int32) -> Bool) -> Int32? {
        ancestors(of: pid, parent: parent).first(where: isApp)
    }
}
