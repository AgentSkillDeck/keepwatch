import AppKit
import Foundation
import KeepwatchCore

// `keepwatch`: the command line for people and AI agents. See CLICommand.usage.

let version = "0.1.0"
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

func run(_ command: CLICommand) -> Int32 {
    switch command {
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
            case .minutes(let m): out("Keepwatch app: keeping your Mac awake for \(m) min.")
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
            out("Keeping your Mac awake for \(m) min (Ctrl-C to stop)…")
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
