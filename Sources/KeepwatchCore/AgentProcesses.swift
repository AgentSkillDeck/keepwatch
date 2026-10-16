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

    /// Script runtimes: an agent written in JavaScript or Python runs as
    /// "node", "bun" or "python3", so for these the script path decides.
    public static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "Python"]
    /// Install paths that identify an agent run through an interpreter
    /// (npm global packages, pipx/venv installs).
    public static let packageMarkers: [(marker: String, agent: String)] = [
        ("@google/gemini-cli", "Gemini CLI"),
        ("@qwen-code/qwen-code", "Qwen Code"),
        ("@sourcegraph/amp", "Amp"),
        ("@anthropic-ai/claude-code", "Claude Code"),
        ("@openai/codex", "Codex"),
        ("opencode-ai", "OpenCode"),
        ("cursor-agent", "Cursor Agent"),
        ("/aider/", "Aider"),
        ("aider-chat", "Aider"),
    ]

    public var names: [String: String]

    public init(names: [String: String] = AgentMatcher.defaultNames) {
        self.names = Dictionary(names.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Whether the executable name is an agent CLI (before argument checks).
    public func isCandidate(_ name: String) -> Bool {
        names[name.lowercased()] != nil || Self.interpreters.contains(name)
    }

    /// The agent a script runtime is running, from its arguments: the script's
    /// file name (`node …/bin/gemini`, `python3 …/bin/aider`, `python3 -m aider`)
    /// or a known install path. Arguments after the script are the agent's own
    /// and never count, so `node server.js --name gemini` isn't an agent.
    func interpretedAgent(_ arguments: [String]) -> String? {
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "-m", i + 1 < arguments.count { return names[arguments[i + 1].lowercased()] }
            if arg.hasPrefix("-") { i += 1; continue }
            // The first non-flag argument is the script.
            let base = ((arg as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            if let agent = names[base] { return agent }
            return Self.packageMarkers.first { arg.contains($0.marker) }?.agent
        }
        return nil
    }

    /// Display name of the agent this process belongs to, or nil.
    public func agentName(for process: RunningProcess) -> String? {
        let direct = names[process.name.lowercased()]
        let interpreted = direct == nil && Self.interpreters.contains(process.name) ? interpretedAgent(process.arguments) : nil
        guard let agent = direct ?? interpreted else { return nil }
        let args = interpreted == nil ? process.arguments : Array(process.arguments.drop { $0.hasPrefix("-") }.dropFirst())
        let idle = args.contains { arg in Self.idleHelperMarkers.contains { arg.contains($0) } }
            || Self.supervisorSubcommands.contains(args.first ?? "")
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

/// One running agent session, for the Agents tab.
public struct AgentSession: Equatable, Hashable, Identifiable, Sendable {
    public var pid: Int32
    public var agent: String
    /// The session's working directory, if readable.
    public var folder: String?
    public var started: Date?
    /// The agent's own session id, when its arguments carry one.
    public var sessionID: String?
    public var id: Int32 { pid }

    public init(pid: Int32, agent: String, folder: String? = nil, started: Date? = nil, sessionID: String? = nil) {
        self.pid = pid; self.agent = agent; self.folder = folder; self.started = started
        self.sessionID = sessionID
    }

    /// Last path component of the folder, or "~" for the home folder.
    public var folderName: String? {
        guard let folder else { return nil }
        if folder == NSHomeDirectory() { return "~" }
        let name = (folder as NSString).lastPathComponent
        return name.isEmpty ? folder : name
    }
}

extension AgentMatcher {
    /// Every agent session in `processes`, oldest first, with folder and start
    /// time from `details`.
    public func sessions(in processes: [RunningProcess],
                         details: (Int32) -> (folder: String?, started: Date?) = { ProcessList.details(of: $0) }) -> [AgentSession] {
        processes.compactMap { p -> AgentSession? in
            guard let agent = agentName(for: p) else { return nil }
            let d = details(p.pid)
            return AgentSession(pid: p.pid, agent: agent, folder: d.folder, started: d.started,
                                sessionID: SessionTitles.sessionID(fromArguments: p.arguments))
        }
        .sorted { ($0.started ?? .distantFuture, $0.pid) < ($1.started ?? .distantFuture, $1.pid) }
    }

    /// Ends a session with a normal quit signal, but only if `pid` is still
    /// that agent (a pid can be reused after the process exits). Never this app.
    public func stop(_ session: AgentSession, current: [RunningProcess]) -> Bool {
        guard session.pid > 1, session.pid != getpid(),
              let p = current.first(where: { $0.pid == session.pid }),
              agentName(for: p) == session.agent else { return false }
        return kill(session.pid, SIGTERM) == 0
    }
}

extension ProcessList {
    /// Working directory and start time of a process we own; nil for either we can't read.
    public static func details(of pid: Int32) -> (folder: String?, started: Date?) {
        var folder: String?
        var vnode = proc_vnodepathinfo()
        let vsize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vsize) == vsize {
            folder = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
                let bytes = raw.prefix { $0 != 0 }
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
        }
        var started: Date?
        var bsd = proc_bsdinfo()
        let bsize = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsize) == bsize, bsd.pbi_start_tvsec > 0 {
            started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
        }
        return (folder, started)
    }
}
