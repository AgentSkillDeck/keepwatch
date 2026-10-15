import Darwin
import Foundation

/// A running process, as much as Keepwatch needs to know about it.
public struct RunningProcess: Equatable, Hashable, Sendable {
    public var pid: Int32
    /// Executable name as the kernel reports it (`proc_name`), max ~32 chars.
    public var name: String
    /// Command-line arguments (argv[1...]), read only for agent candidates.
    public var arguments: [String]

    public init(pid: Int32, name: String, arguments: [String] = []) {
        self.pid = pid
        self.name = name
        self.arguments = arguments
    }
}

/// Recognises AI coding-agent CLIs by executable name.
public struct AgentMatcher: Sendable {
    /// Executable names of agent CLIs. Matching is exact and case-insensitive,
    /// so a shell whose arguments merely mention "claude" never counts.
    public static let defaultNames: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "gemini": "Gemini CLI",
        "aider": "Aider",
        "opencode": "OpenCode",
        "goose": "Goose",
        "amp": "Amp",
        "cursor-agent": "Cursor Agent",
        "qwen": "Qwen Code",
        "crush": "Crush",
    ]

    /// Argument markers of helper processes that are not a session of their
    /// own: Claude Code keeps a pre-warmed "spare" process alive between
    /// sessions, and runs each background session inside a pty host whose
    /// child is the real session (counted on its own).
    public static let idleHelperMarkers = ["--bg-spare", "/spare/", "--bg-pty-host"]
    /// First-argument subcommands of long-lived supervisors that outlive any
    /// session (`claude daemon run`), so they must never keep the Mac awake.
    public static let supervisorSubcommands: Set<String> = ["daemon"]

    public var names: [String: String]

    public init(names: [String: String] = AgentMatcher.defaultNames) {
        self.names = Dictionary(names.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Whether the executable name is an agent CLI (before argument checks).
    public func isCandidate(_ name: String) -> Bool { names[name.lowercased()] != nil }

    /// Display name of the agent this process belongs to, or nil.
    public func agentName(for process: RunningProcess) -> String? {
        guard let agent = names[process.name.lowercased()] else { return nil }
        let idle = process.arguments.contains { arg in Self.idleHelperMarkers.contains { arg.contains($0) } }
            || Self.supervisorSubcommands.contains(process.arguments.first ?? "")
        return idle ? nil : agent
    }

    /// Running agents grouped by display name, with a process count each.
    public func runningAgents(in processes: [RunningProcess]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for p in processes {
            if let agent = agentName(for: p) { counts[agent, default: 0] += 1 }
        }
        return counts
    }
}

extension Dictionary where Key == String, Value == Int {
    /// Total sessions across all agents, and a label such as "Claude Code ×2, Codex".
    public var sessionCount: Int { values.reduce(0) { $0 &+ Swift.max(0, $1) } }

    public var sessionSummary: String {
        keys.sorted().map { name in
            let n = self[name] ?? 0
            return n > 1 ? "\(name) ×\(n)" : name
        }.joined(separator: ", ")
    }
}

/// Lists processes visible to the current user through libproc.
public enum ProcessList {
    /// Upper bound on PIDs read, so a misbehaving kernel answer can't make us
    /// allocate without limit.
    static let maxProcesses = 16_384

    /// Processes, with arguments filled in only for names `wantArguments`
    /// accepts (reading arguments is a syscall per process).
    public static func snapshot(wantArguments: (String) -> Bool = { _ in false }) -> [RunningProcess] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        let capacity = min(Int(estimate) * 2, maxProcesses)
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }
        var result: [RunningProcess] = []
        result.reserveCapacity(Int(written))
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(written)) where pid > 0 {
            let len = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            guard len > 0 else { continue }
            let name = String(decoding: nameBuf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(RunningProcess(pid: pid, name: name, arguments: wantArguments(name) ? arguments(of: pid) : []))
        }
        return result
    }
}

extension ProcessList {
    /// Largest argument block we read (KERN_ARGMAX is typically 1 MiB).
    static let maxArgumentBytes = 64 * 1024

    /// argv[1...] of a process the current user owns, via KERN_PROCARGS2.
    /// Returns [] for processes we can't read. Bounded in size and parsed
    /// with checked offsets: the buffer is kernel-provided but treated as untrusted.
    public static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = maxArgumentBytes
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let bytes = buffer.prefix(min(size, buffer.count))
        // Layout: argc (Int32), exec path, NUL padding, argv[0], argv[1], ...
        let argc = bytes.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard argc > 0, argc < 4096 else { return [] }
        var index = 4
        while index < bytes.count, bytes[bytes.startIndex + index] != 0 { index += 1 } // exec path
        while index < bytes.count, bytes[bytes.startIndex + index] == 0 { index += 1 } // padding
        var args: [String] = []
        var current: [UInt8] = []
        while index < bytes.count, args.count < argc {
            let b = bytes[bytes.startIndex + index]
            if b == 0 { args.append(String(decoding: current, as: UTF8.self)); current.removeAll() } else { current.append(b) }
            index += 1
        }
        return Array(args.dropFirst()) // drop argv[0]
    }
}
