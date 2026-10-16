import AppKit
import Foundation
import KeepwatchCore

// `keepwatch`: the command line for people and AI agents. See CLICommand.usage.

let version = "0.2.0"
let appBundleID = "app.keepwatch.Keepwatch"

func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func err(_ s: String) { FileHandle.standardError.write(Data(("keepwatch: " + s + "\n").utf8)) }

func appRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
}

/// Ask the running app to do something, without bringing it to the front.
func tellApp(_ url: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", url.absoluteString]
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func jsonString<T: Encodable>(_ value: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? e.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

func statusReport() -> StatusReport {
    let power = SystemState.power()
    let pm = SystemState.pmsetSettings()
    let assertions = SystemState.run("/usr/bin/pmset", ["-g", "assertions"]).map(PMSet.parseAssertions) ?? []
    let matcher = AgentMatcher()
    let agents = matcher.runningAgents(in: ProcessList.snapshot(wantArguments: matcher.isCandidate)).keys.sorted()
    let privacy = PrivacyMonitor.snapshot()
    let micUsers = privacy.micUsers.map { u in
        NSRunningApplication(processIdentifier: u.pid)?.localizedName ?? u.bundleID ?? "pid \(u.pid)"
    }
    return StatusReport(
        version: version,
        appRunning: appRunning(),
        power: .init(batteryPercent: power.batteryPercent, onBattery: power.onBattery, charging: power.charging,
                     minutesRemaining: power.minutesRemaining, healthPercent: power.healthPercent,
                     cycleCount: power.cycleCount, lowPowerMode: power.lowPowerMode,
                     thermal: StatusReport.thermalName(power.thermal), lidClosed: power.lidClosed),
        sleep: .init(sleepDisabled: pm?.sleepDisabled ?? false,
                     preventedBy: (pm?.sleepPreventedBy ?? []).filter { $0 != "powerd" },
                     keepwatchHolding: assertions.contains { $0.name.hasPrefix("Keepwatch") }),
        agents: agents,
        privacy: .init(micInUse: privacy.micInUse, cameraInUse: privacy.cameraInUse,
                       micMuted: privacy.micMuted, micUsers: micUsers)
    )
}

/// Hold the Mac awake from this process until `until` returns true.
/// IOKit releases the assertion automatically if this process dies.
func holdAwake(label: String, display: Bool = false, until done: () -> Bool) {
    let system = PowerAssertion(kind: .system, name: "Keepwatch CLI: \(label)")
    let screen = PowerAssertion(kind: .display, name: "Keepwatch CLI: \(label) (display)")
    guard system.hold() else { err("macOS refused the keep-awake request"); exit(2) }
    if display { screen.hold() }
    while !done() { Thread.sleep(forTimeInterval: 2) }
    system.release()
    screen.release()
}

/// Agent sessions with working/idle from two CPU samples one second apart.
func agentRows() -> [AgentRow] {
    let matcher = AgentMatcher()
    let sessions = matcher.sessions(in: ProcessList.snapshot(wantArguments: matcher.isCandidate))
    let first = Dictionary(uniqueKeysWithValues: sessions.compactMap { s in ProcessList.cpuSeconds(of: s.pid).map { (s.pid, $0) } })
    let start = Date()
    if !sessions.isEmpty { Thread.sleep(forTimeInterval: 1) }
    let elapsed = Date().timeIntervalSince(start)
    let titles = SessionTitles.titles(for: sessions)
    return sessions.map { s in
        let used = (ProcessList.cpuSeconds(of: s.pid) ?? 0) - (first[s.pid] ?? 0)
        return AgentRow(agent: s.agent, pid: s.pid, folder: s.folder, started: s.started,
                        activity: AgentActivity.classify(cpuSeconds: used, over: elapsed).rawValue,
                        title: titles[s.pid])
    }
}

struct AgentRow: Encodable {
    var agent: String
    var pid: Int32
    var folder: String?
    var started: Date?
    var activity: String
    /// The session's name, when the agent records one (added in 0.3).
    var title: String?
}

func run(_ command: CLICommand) -> Int32 {
    switch command {
    case .agents(let json):
        let rows = agentRows()
        if json {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            e.dateEncodingStrategy = .iso8601
            out((try? e.encode(rows)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
        } else if rows.isEmpty {
            out("No agents running.")
        } else {
            for r in rows {
                let folder = r.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "?"
                out("\(r.agent)  pid \(r.pid)  \(r.activity)  \(folder)" + (r.title.map { "  “\($0)”" } ?? ""))
            }
        }
        return 0
    case .agentStop(let pid):
        let matcher = AgentMatcher()
        let current = ProcessList.snapshot(wantArguments: matcher.isCandidate)
        guard let session = matcher.sessions(in: current).first(where: { $0.pid == pid }) else {
            err("pid \(pid) is not a running agent session"); return 2
        }
        guard matcher.stop(session, current: current) else { err("couldn't stop pid \(pid)"); return 2 }
        out("Asked \(session.agent) (pid \(pid)) to quit."); return 0
    case .privacy(let json):
        let p = PrivacyMonitor.snapshot()
        let log = PrivacyLog.load()
        if json {
            struct Report: Encodable { var micInUse: Bool; var cameraInUse: Bool; var micMuted: Bool?; var history: [PrivacyEvent] }
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            e.dateEncodingStrategy = .iso8601
            let r = Report(micInUse: p.micInUse, cameraInUse: p.cameraInUse, micMuted: p.micMuted, history: Array(log.recent.prefix(50)))
            out((try? e.encode(r)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        } else {
            out("Mic \(p.micMuted == true ? "muted" : (p.micInUse ? "IN USE" : "not in use")), camera \(p.cameraInUse ? "IN USE" : "not in use")")
            for e in log.recent.prefix(10) {
                let what = "\(e.device == .mic ? "Mic" : "Camera") \(e.on ? "on" : "off")" + (e.apps.isEmpty ? "" : " (\(e.apps.joined(separator: ", ")))")
                out("  \(e.date.formatted(date: .abbreviated, time: .shortened))  \(what)")
            }
            if log.events.isEmpty { out("  No history yet (the Keepwatch app records it).") }
        }
        return 0
    case .apps(let json):
        let apps = TopApps.current(limit: 15)
        if json {
            struct Row: Encodable { var name: String; var path: String; var bytes: UInt64; var processes: Int; var system: Bool }
            out(jsonString(apps.map { Row(name: $0.name, path: $0.path, bytes: $0.bytes, processes: $0.pids.count, system: $0.isSystem) }))
        } else {
            for a in apps {
                out(String(format: "%10@  %@%@", TopApps.describe(bytes: a.bytes), a.name,
                           (a.pids.count > 1 ? " (\(a.pids.count) processes)" : "") + (a.isSystem ? "  macOS" : "")))
            }
        }
        return 0
    case .security(let json):
        let checks = SecurityCheck.allCases.map { ($0, $0.read()) }
        if json {
            struct Row: Encodable { var check: String; var state: String; var ok: Bool? }
            out(jsonString(checks.map { c, s in
                Row(check: c.rawValue, state: s.label, ok: { if case .good = s { return true }; if case .weak = s { return false }; return nil }())
            }))
        } else {
            for (c, s) in checks {
                let mark: String = { if case .good = s { return "ok " }; if case .weak = s { return "!! " }; return "?  " }()
                out("\(mark) \(c.title): \(s.label)")
            }
        }
        return 0
    case .lidStart(let hours):
        guard appRunning() else { err("open the Keepwatch app first; it shows the password prompt"); return 2 }
        var info: [String: Any] = [:]
        if let hours { info["hours"] = hours }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(LidRequest.notificationName), object: nil, userInfo: info, deliverImmediately: true)
        out("Asked Keepwatch to start a lid session. macOS will ask for your password on the Mac.")
        out("Check with: keepwatch status")
        return 0
    case .help:
        out(CLICommand.usage); return 0
    case .version:
        out("keepwatch \(version)"); return 0
    case .status(let json):
        let report = statusReport()
        out(json ? jsonString(report) : report.text()); return 0
    case .ports(let json):
        let ports = ListeningPorts.current()
        if json {
            struct Row: Encodable { var port: Int; var address: String; var pid: Int32; var process: String; var system: Bool }
            out(jsonString(ports.map { Row(port: $0.port, address: $0.address, pid: $0.pid, process: $0.process, system: $0.isSystem) }))
        } else if ports.isEmpty {
            out("Nothing of yours is listening.")
        } else {
            for p in ports { out(String(format: ":%-6d %@  %@%@", p.port, p.process, p.address, p.isSystem ? "  (macOS)" : "")) }
        }
        return 0
    case .mic(let mute):
        guard PrivacyMonitor.setMicMuted(mute) else { err("the default input device has no mute control"); return 2 }
        out(mute ? "Microphone muted." : "Microphone unmuted."); return 0
    case .lidEnd:
        let pm = SystemState.pmsetSettings()
        guard pm?.sleepDisabled == true else { out("No lid session is running; sleep is normal."); return 0 }
        let stop = LidWatchdog.defaultStopFile()
        guard FileManager.default.createFile(atPath: stop.path, contents: Data("keepwatch lid end".utf8)) else {
            err("couldn't write \(stop.path)"); return 2
        }
        out("Asked the lid session to end. Sleep turns back on within 30 seconds.")
        out("If sleep was turned off by something other than Keepwatch, this has no effect.")
        return 0
    case .awake(let request):
        if appRunning(), let url = command.appURL {
            guard tellApp(url) else { err("couldn't reach the Keepwatch app"); return 2 }
            switch request {
            case .minutes(let m): out("Keepwatch app: keeping your Mac awake for \(AwakeDuration.describe(TimeInterval(m) * 60)).")
            case .indefinitely: out("Keepwatch app: keeping your Mac awake until 'keepwatch awake --off'.")
            case .whileAgentsRun: out("Keepwatch app: keeping your Mac awake while agents run.")
            case .off: out("Keepwatch app: keep-awake off.")
            }
            return 0
        }
        // No app: hold the assertion from this process.
        switch request {
        case .off:
            out("The Keepwatch app isn't running. To stop a 'keepwatch awake' you started here, press Ctrl-C in its terminal.")
            return 0
        case .minutes(let m):
            let end = Date().addingTimeInterval(TimeInterval(m) * 60)
            out("Keeping your Mac awake for \(AwakeDuration.describe(TimeInterval(m) * 60)) (Ctrl-C to stop)…")
            holdAwake(label: "\(m) min") { Date() >= end }
        case .indefinitely:
            out("Keeping your Mac awake until you press Ctrl-C…")
            holdAwake(label: "until stopped") { false }
        case .whileAgentsRun:
            var engine = KeepAwakeEngine()
            engine.set(.whileAgentsRun(grace: 120))
            let matcher = AgentMatcher()
            out("Keeping your Mac awake while agents run (Ctrl-C to stop)…")
            var everSeen = false
            holdAwake(label: "while agents run") {
                let agents = Set(matcher.runningAgents(in: ProcessList.snapshot(wantArguments: matcher.isCandidate)).keys)
                if !agents.isEmpty { everSeen = true }
                let d = engine.tick(now: Date(), agents: agents)
                for case .agentFinished(let name) in d.events { out("\(name) finished.") }
                return everSeen && !d.holdAssertion
            }
            out("All agents finished; your Mac can sleep again.")
        }
        return 0
    case .run(let argv, let display):
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = argv
        signal(SIGINT, SIG_IGN) // the child gets Ctrl-C from the terminal; we wait for it
        do { try child.run() } catch { err("couldn't start \(argv[0]): \(error.localizedDescription)"); return 2 }
        holdAwake(label: "running \(argv[0])", display: display) { !child.isRunning }
        return child.terminationStatus
    }
}

do {
    let command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
    exit(run(command))
} catch {
    err("\(error)")
    exit(1)
}
