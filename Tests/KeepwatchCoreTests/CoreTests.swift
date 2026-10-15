import XCTest
@testable import KeepwatchCore

final class PMSetTests: XCTestCase {
    // Captured from a MacBook running macOS 26.5 with Amphetamine and caffeinate active.
    let settingsOutput = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     disksleep            10
     sleep                1 (sleep prevented by caffeinate, powerd, Amphetamine, caffeinate)
     hibernatemode        3
     displaysleep         2 (display sleep prevented by Amphetamine)
     lowpowermode         1
    """

    func testParsesSettingsAndPreventers() {
        let s = PMSet.parseSettings(settingsOutput)
        XCTAssertFalse(s.sleepDisabled)
        XCTAssertEqual(s.lowPowerMode, true)
        XCTAssertEqual(s.sleepMinutes, 1)
        XCTAssertEqual(s.displaySleepMinutes, 2)
        XCTAssertEqual(s.sleepPreventedBy, ["caffeinate", "powerd", "Amphetamine"])
    }

    func testDetectsSleepDisabled() {
        let s = PMSet.parseSettings(settingsOutput + "\n SleepDisabled\t\t1\n")
        XCTAssertTrue(s.sleepDisabled)
        XCTAssertFalse(PMSet.parseSettings(" SleepDisabled  0").sleepDisabled)
    }

    func testEmptyAndGarbageInputDoNotCrash() {
        XCTAssertEqual(PMSet.parseSettings("").sleepPreventedBy, [])
        XCTAssertEqual(PMSet.parseSettings("::::\n\t\t\n sleep").sleepMinutes, nil)
        XCTAssertEqual(PMSet.parsePreventers("1 (sleep prevented by "), [])
        XCTAssertEqual(PMSet.parseAssertions("pid x(y): garbage"), [])
    }

    func testParsesOwnedAssertions() {
        let out = """
        Listed by owning process:
           pid 10730(Amphetamine): [0x00000875000183ac] 93:13:07 PreventUserIdleSystemSleep named: "Amphetamine (Single-Use - System)"
           pid 26450(caffeinate): [0x00017d590001a11b] 00:03:31 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        \tDetails: caffeinate asserting for 300 secs
        """
        let rows = PMSet.parseAssertions(out)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], .init(pid: 10730, process: "Amphetamine", type: "PreventUserIdleSystemSleep",
                                      name: "Amphetamine (Single-Use - System)"))
        XCTAssertEqual(rows[1].process, "caffeinate")
    }

    func testCommandsAreFixedAndEscaped() {
        XCTAssertEqual(PMSet.disableSleepCommand(true), "/usr/bin/pmset -a disablesleep 1")
        XCTAssertEqual(PMSet.disableSleepCommand(false), "/usr/bin/pmset -a disablesleep 0")
        let script = PMSet.adminAppleScript(for: "echo \"hi\"", prompt: "Keepwatch \"lid\" mode")
        XCTAssertEqual(script, #"do shell script "echo \"hi\"" with prompt "Keepwatch \"lid\" mode" with administrator privileges"#)
    }
}

final class AgentMatcherTests: XCTestCase {
    func testMatchesExecutableNamesExactly() {
        let m = AgentMatcher()
        let procs = [
            RunningProcess(pid: 1, name: "claude"),
            RunningProcess(pid: 2, name: "claude"),
            RunningProcess(pid: 3, name: "Codex"),
            RunningProcess(pid: 4, name: "zsh"),          // a shell that runs claude doesn't count
            RunningProcess(pid: 5, name: "claude-helper"), // prefix isn't a match
        ]
        XCTAssertEqual(m.runningAgents(in: procs), ["Claude Code": 2, "Codex": 1])
    }

    func testSnapshotSeesThisTestProcess() {
        let me = getpid()
        XCTAssertTrue(ProcessList.snapshot().contains { $0.pid == me })
    }
}

final class KeepAwakeEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testOffNeverHolds() {
        var e = KeepAwakeEngine()
        XCTAssertFalse(e.tick(now: t0, agents: ["Codex"]).holdAssertion)
    }

    func testTimerHoldsThenEndsOnce() {
        var e = KeepAwakeEngine()
        e.set(.until(t0.addingTimeInterval(60)))
        let d1 = e.tick(now: t0, agents: [])
        XCTAssertTrue(d1.holdAssertion)
        XCTAssertEqual(d1.remaining, 60)
        let d2 = e.tick(now: t0.addingTimeInterval(61), agents: [])
        XCTAssertFalse(d2.holdAssertion)
        XCTAssertEqual(d2.events, [.timerEnded])
        XCTAssertEqual(e.mode, .off)
        XCTAssertEqual(e.tick(now: t0.addingTimeInterval(62), agents: []).events, [])
    }

    func testWhileAgentsRunWithGraceAndFinishEvents() {
        var e = KeepAwakeEngine()
        e.set(.whileAgentsRun(grace: 120))
        XCTAssertFalse(e.tick(now: t0, agents: []).holdAssertion, "no agent yet: don't hold")
        XCTAssertTrue(e.tick(now: t0.addingTimeInterval(1), agents: ["Claude Code"]).holdAssertion)
        let finished = e.tick(now: t0.addingTimeInterval(2), agents: [])
        XCTAssertTrue(finished.holdAssertion, "inside grace")
        XCTAssertEqual(finished.events, [.agentFinished("Claude Code")])
        let idle = e.tick(now: t0.addingTimeInterval(200), agents: [])
        XCTAssertFalse(idle.holdAssertion)
        XCTAssertEqual(idle.events, [.agentsIdle])
        XCTAssertEqual(e.mode, .whileAgentsRun(grace: 120), "stays armed for the next agent")
        XCTAssertTrue(e.tick(now: t0.addingTimeInterval(300), agents: ["Codex"]).holdAssertion)
    }

    func testFinishEventsFireEvenWhenOff() {
        var e = KeepAwakeEngine()
        _ = e.tick(now: t0, agents: ["Codex", "Claude Code"])
        XCTAssertEqual(e.tick(now: t0, agents: ["Codex"]).events, [.agentFinished("Claude Code")])
    }

    func testNegativeGraceIsTreatedAsZero() {
        var e = KeepAwakeEngine()
        e.set(.whileAgentsRun(grace: -5))
        _ = e.tick(now: t0, agents: ["Codex"])
        XCTAssertFalse(e.tick(now: t0.addingTimeInterval(1), agents: []).holdAssertion)
    }
}

final class LidModeGuardTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let policy = LidModePolicy()

    func testLaunchRestoresOurStaleSettingAndAsksAboutForeignOne() {
        let ours = LidModeIntent(enabled: true, since: now)
        XCTAssertEqual(LidModeGuard.onLaunch(systemSleepDisabled: false, intent: .off, watchdogAlive: false), .none)
        XCTAssertEqual(LidModeGuard.onLaunch(systemSleepDisabled: false, intent: ours, watchdogAlive: false), .none)
        XCTAssertEqual(LidModeGuard.onLaunch(systemSleepDisabled: true, intent: ours, watchdogAlive: true), .none)
        XCTAssertEqual(LidModeGuard.onLaunch(systemSleepDisabled: true, intent: ours, watchdogAlive: false),
                       .restore(.staleAfterLaunch))
        XCTAssertEqual(LidModeGuard.onLaunch(systemSleepDisabled: true, intent: .off, watchdogAlive: true), .askAboutForeignSetting)
        XCTAssertEqual(LidModeGuard.onLaunch(systemSleepDisabled: true, intent: ours, watchdogAlive: true,
                                             bootTime: now.addingTimeInterval(60)), .restore(.staleAfterLaunch),
                       "booted after the session started: watchdog can't be alive")
        XCTAssertEqual(LidModeGuard.onLaunch(systemSleepDisabled: true, intent: ours, watchdogAlive: true,
                                             bootTime: now.addingTimeInterval(-86400)), .none)
    }

    func testTickRules() {
        let on = LidModeIntent(enabled: true, since: now, expires: now.addingTimeInterval(3600))
        func tick(at t: TimeInterval = 0, pct: Int? = 80, battery: Bool = false,
                  thermal: LidModePolicy.Thermal = .nominal, policy p: LidModePolicy? = nil) -> LidModeAction {
            LidModeGuard.onTick(intent: on, policy: p ?? policy, now: now.addingTimeInterval(t),
                                batteryPercent: pct, onBattery: battery, thermal: thermal)
        }
        XCTAssertEqual(tick(), .none)
        XCTAssertEqual(tick(at: 3600), .restore(.expired))
        XCTAssertEqual(tick(thermal: .fair), .none)
        XCTAssertEqual(tick(thermal: .serious), .restore(.thermal))
        XCTAssertEqual(tick(battery: true), .restore(.onBattery), "power-only by default")
        var allowBattery = policy
        allowBattery.requireExternalPower = false
        XCTAssertEqual(tick(pct: 50, battery: true, policy: allowBattery), .none)
        XCTAssertEqual(tick(pct: 15, battery: true, policy: allowBattery), .restore(.lowBattery))
        XCTAssertEqual(LidModeGuard.onTick(intent: .off, policy: policy, now: now, batteryPercent: 1,
                                           onBattery: true, thermal: .critical), .none)
    }

    func testBootTimeIsReadableAndInThePast() {
        let boot = BootTime.current()
        XCTAssertNotNil(boot)
        if let boot { XCTAssertLessThan(boot, Date()) }
    }

    func testMaxDurationCapsEvenWithoutExpiry() {
        let on = LidModeIntent(enabled: true, since: now, expires: nil)
        XCTAssertEqual(LidModeGuard.onTick(intent: on, policy: policy, now: now.addingTimeInterval(policy.maxDuration),
                                           batteryPercent: nil, onBattery: false, thermal: .nominal), .restore(.expired))
    }

    func testExpiryIsClamped() {
        XCTAssertEqual(LidModeGuard.expiry(requested: 10, policy: policy, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(LidModeGuard.expiry(requested: 1e9, policy: policy, now: now), now.addingTimeInterval(policy.maxDuration))
        XCTAssertEqual(LidModeGuard.expiry(requested: nil, policy: policy, now: now), now.addingTimeInterval(policy.maxDuration))
    }
}

final class PowerAssertionTests: XCTestCase {
    func testHoldAndReleaseAreIdempotent() {
        let a = PowerAssertion(kind: .system, name: "Keepwatch unit test")
        XCTAssertTrue(a.hold())
        XCTAssertTrue(a.hold())
        XCTAssertTrue(a.isHeld)
        a.release()
        a.release()
        XCTAssertFalse(a.isHeld)
    }
}

final class URLCommandTests: XCTestCase {
    func parse(_ s: String) -> URLCommand? { URL(string: s).flatMap(URLCommand.parse) }

    func testParsesCommands() {
        XCTAssertEqual(parse("keepwatch://awake?minutes=90"), .awake(minutes: 90))
        XCTAssertEqual(parse("keepwatch://awake"), .awakeIndefinitely)
        XCTAssertEqual(parse("KEEPWATCH://awake/agents"), .awakeWhileAgentsRun)
        XCTAssertEqual(parse("keepwatch://awake/off"), .awakeOff)
        XCTAssertEqual(parse("keepwatch://mic/mute"), .micMute(true))
        XCTAssertEqual(parse("keepwatch://mic/unmute"), .micMute(false))
        XCTAssertEqual(parse("keepwatch://lid/end"), .endLidSession)
        XCTAssertEqual(parse("keepwatch://dashboard"), .dashboard)
    }

    func testRejectsBadInputAndCapsDuration() {
        XCTAssertNil(parse("https://awake?minutes=5"))
        XCTAssertNil(parse("keepwatch://awake?minutes=-3"))
        XCTAssertNil(parse("keepwatch://awake?minutes=abc"))
        XCTAssertNil(parse("keepwatch://lid/start"), "lid sessions can't be started from a URL")
        XCTAssertNil(parse("keepwatch://unknown"))
        XCTAssertEqual(parse("keepwatch://awake?minutes=999999999"), .awake(minutes: URLCommand.maxMinutes))
    }
}

final class AgentHelperTests: XCTestCase {
    func testIgnoresClaudeSpareHelpers() {
        let m = AgentMatcher()
        let procs = [
            RunningProcess(pid: 1, name: "claude", arguments: ["bg-spare", "--bg-spare", "/tmp/cc-daemon-502/x/spare/a.claim.sock"]),
            RunningProcess(pid: 2, name: "claude", arguments: ["bg-pty-host", "--bg-pty-host", "/tmp/cc-daemon-502/x/spare/a.pty.sock"]),
        ]
        XCTAssertEqual(m.runningAgents(in: procs), [:])
        XCTAssertNil(m.agentName(for: RunningProcess(pid: 4, name: "claude", arguments: ["daemon", "run", "--origin", "transient"])))
        XCTAssertNotNil(m.agentName(for: RunningProcess(pid: 5, name: "claude", arguments: ["--session-id", "x"])))
        XCTAssertEqual(m.runningAgents(in: procs + [RunningProcess(pid: 3, name: "claude")]), ["Claude Code": 1])
    }

    func testBackgroundSessionPtyHostCountsOnce() {
        let m = AgentMatcher()
        let procs = [
            RunningProcess(pid: 10, name: "claude", arguments: ["--bg-pty-host", "/tmp/cc-daemon-502/x/pty/s.sock", "--", "/opt/claude"]),
            RunningProcess(pid: 11, name: "claude", arguments: ["--session-id", "s", "--agent", "claude"]),
            RunningProcess(pid: 12, name: "claude"),
            RunningProcess(pid: 13, name: "codex"),
        ]
        let running = m.runningAgents(in: procs)
        XCTAssertEqual(running, ["Claude Code": 2, "Codex": 1])
        XCTAssertEqual(running.sessionCount, 3)
        XCTAssertEqual(running.sessionSummary, "Claude Code ×2, Codex")
        XCTAssertEqual([String: Int]().sessionCount, 0)
    }

    func testReadsOwnArguments() {
        let args = ProcessList.arguments(of: getpid())
        XCTAssertEqual(args, Array(CommandLine.arguments.dropFirst()))
        XCTAssertEqual(ProcessList.arguments(of: 1), [], "launchd isn't ours: no crash, empty")
        XCTAssertEqual(ProcessList.arguments(of: -5), [])
    }

    func testLiveAgentScanExcludesSpares() {
        let m = AgentMatcher()
        let all = ProcessList.snapshot(wantArguments: m.isCandidate)
        let spares = all.filter { m.isCandidate($0.name) && $0.arguments.contains("--bg-spare") }
        for s in spares { XCTAssertNil(m.agentName(for: s)) }
        print("LIVE agents:", m.runningAgents(in: all), "spares ignored:", spares.count)
    }
}

final class ListeningPortsTests: XCTestCase {
    func testParsesLsofFieldOutput() {
        let out = "p799\ncrapportd\nf10\nn*:55992\nf11\nn*:55992\np900\ncnode\nf3\nn127.0.0.1:3000\nf4\nn[::1]:3000\np901\ncbad\nn*:notaport\nn*:70000\n"
        XCTAssertEqual(ListeningPorts.parse(out), [
            ListeningPort(port: 3000, address: "127.0.0.1", pid: 900, process: "node"),
            ListeningPort(port: 55992, address: "*", pid: 799, process: "rapportd"),
        ])
        XCTAssertEqual(ListeningPorts.parse(""), [])
        XCTAssertEqual(ListeningPorts.parse("n*:80\n"), [], "no pid yet: ignored")
    }

    func testStopRefusesSelfAndSystem() {
        XCTAssertFalse(ListeningPorts.stop(pid: getpid()))
        XCTAssertFalse(ListeningPorts.stop(pid: 1))
        XCTAssertFalse(ListeningPorts.stop(pid: 0))
    }

    func testSystemPathDetection() {
        XCTAssertTrue(ListeningPorts.isSystemPath("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"))
        XCTAssertTrue(ListeningPorts.isSystemPath("/usr/libexec/rapportd"))
        XCTAssertTrue(ListeningPorts.isSystemPath(nil), "unknown: treat as system")
        XCTAssertFalse(ListeningPorts.isSystemPath("/opt/homebrew/bin/node"))
        XCTAssertFalse(ListeningPorts.isSystemPath("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    }

    func testLiveListMarksControlCenterAsSystem() {
        let ports = ListeningPorts.current()
        print("LIVE ports:", ports.prefix(10).map { "\($0.port) \($0.process) system=\($0.isSystem)" })
        for p in ports where p.process == "ControlCenter" || p.process == "rapportd" { XCTAssertTrue(p.isSystem, p.process) }
    }
}

final class CLICommandTests: XCTestCase {
    func p(_ s: String) throws -> CLICommand { try CLICommand.parse(s.split(separator: " ").map(String.init)) }

    func testParsesCommands() throws {
        XCTAssertEqual(try CLICommand.parse([]), .help)
        XCTAssertEqual(try p("status --json"), .status(json: true))
        XCTAssertEqual(try p("awake"), .awake(.indefinitely))
        XCTAssertEqual(try p("awake --minutes 90"), .awake(.minutes(90)))
        XCTAssertEqual(try p("awake --minutes 99999"), .awake(.minutes(URLCommand.maxMinutes)))
        XCTAssertEqual(try p("awake --agents"), .awake(.whileAgentsRun))
        XCTAssertEqual(try p("awake --off"), .awake(.off))
        XCTAssertEqual(try p("run -- npm test --watch"), .run(command: ["npm", "test", "--watch"], display: false))
        XCTAssertEqual(try p("run --display -- make"), .run(command: ["make"], display: true))
        XCTAssertEqual(try p("mic mute"), .mic(mute: true))
        XCTAssertEqual(try p("lid end"), .lidEnd)
        XCTAssertEqual(try p("ports"), .ports(json: false))
    }

    func testRejectsBadInput() {
        for bad in ["awake --minutes 0", "awake --minutes x", "awake --bogus", "run", "run --", "run npm",
                    "mic", "lid", "status --yaml", "frobnicate"] {
            XCTAssertThrowsError(try p(bad), bad)
        }
    }

    func testAgentsCannotStartLidSessions() {
        XCTAssertThrowsError(try p("lid start")) { error in
            XCTAssertTrue("\(error)".contains("administrator password"))
        }
    }

    func testAppURLsMatchURLCommands() throws {
        for cmd in ["awake", "awake --minutes 5", "awake --agents", "awake --off", "lid end"] {
            let url = try XCTUnwrap(try p(cmd).appURL, cmd)
            XCTAssertNotNil(URLCommand.parse(url), "app must understand the CLI's URL for '\(cmd)'")
        }
        XCTAssertNil(try p("status").appURL)
    }

    func testStatusJSONFieldNamesAreStable() throws {
        let r = StatusReport(version: "0", appRunning: false,
                             power: .init(batteryPercent: 50, onBattery: true, charging: false, minutesRemaining: 90,
                                          healthPercent: 90, cycleCount: 10, lowPowerMode: false, thermal: "nominal", lidClosed: false),
                             sleep: .init(sleepDisabled: false, preventedBy: ["Amphetamine"], keepwatchHolding: true),
                             agents: ["Codex"],
                             privacy: .init(micInUse: false, cameraInUse: false, micMuted: false, micUsers: []))
        let json = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
        for key in ["appRunning", "batteryPercent", "sleepDisabled", "keepwatchHolding", "agents", "micInUse", "cameraInUse"] {
            XCTAssertTrue(json.contains("\"\(key)\""), key)
        }
        XCTAssertTrue(r.text().contains("Agents    Codex"))
    }
}

final class CLIInstallerTests: XCTestCase {
    func testInstallsIntoFirstWritableAndRespectsOthersFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kwcli-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("locked"), taken = root.appendingPathComponent("taken"),
            free = root.appendingPathComponent("free")
        for d in [locked, taken, free] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path); try? fm.removeItem(at: root) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        try "someone else's".write(to: taken.appendingPathComponent("keepwatch"), atomically: true, encoding: .utf8)
        let cli = "/Applications/Keepwatch.app/Contents/MacOS/keepwatch-cli"
        let dirs = [locked.path, taken.path, free.path]
        XCTAssertEqual(CLIInstaller.install(cliPath: cli, directories: dirs), .installed(free.path + "/keepwatch"))
        XCTAssertEqual(CLIInstaller.install(cliPath: cli, directories: dirs), .alreadyInstalled(free.path + "/keepwatch"))
        XCTAssertEqual(try String(contentsOf: taken.appendingPathComponent("keepwatch"), encoding: .utf8), "someone else's")
        // App moved: our stale link is replaced.
        let moved = "/Users/x/Apps/Keepwatch.app/Contents/MacOS/keepwatch-cli"
        XCTAssertEqual(CLIInstaller.install(cliPath: moved, directories: dirs), .installed(free.path + "/keepwatch"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: free.path + "/keepwatch"), moved)
    }
}
