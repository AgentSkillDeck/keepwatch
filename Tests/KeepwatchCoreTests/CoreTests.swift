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
        XCTAssertEqual(URLCommand.maxMinutes, 30 * 24 * 60)
        XCTAssertEqual(parse("keepwatch://awake?for=2d"), .awake(minutes: 2880))
        XCTAssertEqual(parse("keepwatch://awake?for=1h30m"), .awake(minutes: 90))
        XCTAssertNil(parse("keepwatch://awake?for=soon"))
        XCTAssertNil(parse("keepwatch://awake?for=" + String(repeating: "9", count: 500) + "h"))
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

    func testSessionsAreGroupedOldestFirstAndStopChecksThePid() {
        let m = AgentMatcher()
        let procs = [
            RunningProcess(pid: 20, name: "claude"),
            RunningProcess(pid: 21, name: "codex"),
            RunningProcess(pid: 22, name: "claude", arguments: ["--bg-spare"]),
            RunningProcess(pid: 23, name: "zsh"),
        ]
        let t0 = Date(timeIntervalSince1970: 1_000)
        let sessions = m.sessions(in: procs) { pid in
            (pid == 20 ? "/Users/x/app" : nil, pid == 20 ? t0.addingTimeInterval(60) : t0)
        }
        XCTAssertEqual(sessions.map(\.pid), [21, 20])
        XCTAssertEqual(sessions.last?.folderName, "app")
        XCTAssertNil(sessions.first?.folderName)
        // A pid that is no longer that agent (gone, or reused by another program) is never signalled.
        XCTAssertFalse(m.stop(AgentSession(pid: 20, agent: "Claude Code"), current: [RunningProcess(pid: 20, name: "zsh")]))
        XCTAssertFalse(m.stop(AgentSession(pid: 20, agent: "Claude Code"), current: []))
        XCTAssertFalse(m.stop(AgentSession(pid: getpid(), agent: "Claude Code"),
                              current: [RunningProcess(pid: getpid(), name: "claude")]))
        XCTAssertFalse(m.stop(AgentSession(pid: 1, agent: "Claude Code"), current: [RunningProcess(pid: 1, name: "claude")]))
    }

    func testReadsOwnProcessDetails() {
        let d = ProcessList.details(of: getpid())
        XCTAssertEqual(d.folder, FileManager.default.currentDirectoryPath)
        XCTAssertNotNil(d.started)
        XCTAssertNil(ProcessList.details(of: -5).folder)
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

    func testLidStartWithoutAppSaysWhereToGetIt() {
        let missing = CLICommand.lidNeedsAppMessage(appInstalled: false)
        XCTAssertTrue(missing.contains("https://github.com/AgentSkillDeck/keepwatch/releases/latest"), missing)
        XCTAssertTrue(missing.contains("Keepwatch app"), missing)
        let closed = CLICommand.lidNeedsAppMessage(appInstalled: true)
        XCTAssertTrue(closed.contains("Open Keepwatch"), closed)
    }

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
        XCTAssertEqual(try p("awake --for 3h"), .awake(.minutes(180)))
        XCTAssertEqual(try p("awake --for 1h 30m"), .awake(.minutes(90)))
        XCTAssertEqual(try p("awake --for 2w"), .awake(.minutes(20_160)))
        XCTAssertEqual(try p("awake --for 9w"), .awake(.minutes(URLCommand.maxMinutes)))
        XCTAssertEqual(try p("agents --json"), .agents(json: true))
        XCTAssertEqual(try p("agents stop 4242"), .agentStop(pid: 4242))
        XCTAssertEqual(try p("privacy"), .privacy(json: false))
        XCTAssertEqual(try p("security --json"), .security(json: true))
        XCTAssertEqual(try p("apps"), .apps(json: false))
        XCTAssertEqual(try p("apps --json"), .apps(json: true))
        XCTAssertEqual(try p("lid start"), .lidStart(hours: nil))
        XCTAssertEqual(try p("lid start --hours 2.7"), .lidStart(hours: 2.5))
    }

    func testUntilUsesTheNextOccurrence() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 17, minute: 0)))
        XCTAssertEqual(try CLICommand.parse(["awake", "--until", "18:30"], now: now, calendar: cal), .awake(.minutes(90)))
        XCTAssertEqual(try CLICommand.parse(["awake", "--until", "16:00"], now: now, calendar: cal), .awake(.minutes(23 * 60)))
        for bad in ["24:00", "9", "18:3x", "-1:00", "18:60", "١٨:٣٠"] {
            XCTAssertThrowsError(try CLICommand.parse(["awake", "--until", bad], now: now, calendar: cal), bad)
        }
    }

    func testRejectsBadInput() {
        for bad in ["awake --minutes 0", "awake --minutes x", "awake --bogus", "run", "run --", "run npm",
                    "mic", "lid", "status --yaml", "frobnicate", "awake --for", "awake --for 3", "awake --for 0h",
                    "awake --for 3x", "awake --for -2h", "agents stop", "agents stop 1", "agents stop abc",
                    "lid start --hours 0", "lid start --hours 13", "lid start --hours nan", "lid start now"] {
            XCTAssertThrowsError(try p(bad), bad)
        }
    }

    /// The CLI may only ask: `lid start` has no URL (web pages can open URLs),
    /// and the app answers a request by showing the macOS password prompt.
    func testAgentsCannotStartLidSessions() throws {
        XCTAssertNil(try p("lid start").appURL)
        XCTAssertNil(try p("lid start --hours 3").appURL)
        XCTAssertNil(URLCommand.parse(URL(string: "keepwatch://lid/start?hours=3")!))
        XCTAssertNil(LidRequest.hours(from: nil))
        XCTAssertNil(LidRequest.hours(from: ["hours": "abc"]))
        XCTAssertNil(LidRequest.hours(from: ["hours": Double.nan]))
        XCTAssertNil(LidRequest.hours(from: ["hours": -1.0]))
        XCTAssertEqual(LidRequest.hours(from: ["hours": 99.0]), 12)
        XCTAssertEqual(LidRequest.hours(from: ["hours": "0.1"]), 0.5)
        XCTAssertEqual(LidRequest.hours(from: ["hours": NSNumber(value: 3)]), 3)
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

final class AwakeDurationTests: XCTestCase {
    func testParsesLengths() {
        XCTAssertEqual(AwakeDuration.parse("45m"), 2_700)
        XCTAssertEqual(AwakeDuration.parse("1.5h"), 5_400)
        XCTAssertEqual(AwakeDuration.parse("1h30m"), 5_400)
        XCTAssertEqual(AwakeDuration.parse("3 Days"), 259_200)
        XCTAssertEqual(AwakeDuration.parse("1w 1d"), 691_200)
        XCTAssertEqual(AwakeDuration.parse("52w"), AwakeDuration.maxSeconds)
    }

    func testRejectsJunk() {
        for bad in ["", "3", "h", "0m", "1.2.3h", "3 fortnights", "-1h", "1e400h", "1h junk", "١h",
                    String(repeating: "1", count: 65) + "m", "nan h", "inf h"] {
            XCTAssertNil(AwakeDuration.parse(bad), bad)
        }
    }

    func testDescribeAndMinutes() {
        XCTAssertEqual(AwakeDuration.describe(7_200), "2 h")
        XCTAssertEqual(AwakeDuration.describe(7_500), "2 h 5 min")
        XCTAssertEqual(AwakeDuration.describe(90_000), "1 d 1 h")
        XCTAssertEqual(AwakeDuration.describe(691_200), "1 w 1 d")
        XCTAssertEqual(AwakeDuration.describe(.nan), "0 s")
        XCTAssertEqual(AwakeDuration.describe(-5), "0 s")
        XCTAssertEqual(AwakeDuration.minutes(61), 2)
        XCTAssertEqual(AwakeDuration.minutes(.infinity), 1)
        XCTAssertEqual(AwakeDuration.minutes(1e12), Int(AwakeDuration.maxSeconds / 60))
        XCTAssertNil(AwakeDuration.seconds(0, .hours))
        XCTAssertNil(AwakeDuration.seconds(.nan, .days))
        XCTAssertEqual(AwakeDuration.seconds(1e9, .weeks), AwakeDuration.maxSeconds)
    }
}

final class ActivityTests: XCTestCase {
    func testClassifiesCPUShare() {
        XCTAssertEqual(AgentActivity.classify(cpuSeconds: 0.5, over: 2), .working)
        XCTAssertEqual(AgentActivity.classify(cpuSeconds: 0.01, over: 2), .idle)
        XCTAssertEqual(AgentActivity.classify(cpuSeconds: 1, over: 0), .idle)
        XCTAssertEqual(AgentActivity.classify(cpuSeconds: .nan, over: 2), .idle)
    }

    func testReportsQuietOnceAfterRealWork() {
        var t = AgentActivityTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        var cpu = 0.0
        XCTAssertEqual(t.update(cpu: [7: cpu], now: t0), [])
        // Work for 2 minutes.
        for s in stride(from: 2, through: 120, by: 2) {
            cpu += 1
            XCTAssertEqual(t.update(cpu: [7: cpu], now: t0.addingTimeInterval(TimeInterval(s))), [])
        }
        XCTAssertEqual(t.states[7]?.activity, .working)
        // Go quiet: reported once after 45 s, then not again.
        var reported: [Int32] = []
        for s in stride(from: 122, through: 300, by: 2) {
            reported += t.update(cpu: [7: cpu], now: t0.addingTimeInterval(TimeInterval(s)))
        }
        XCTAssertEqual(reported, [7])
        // A short blip of work isn't enough for another notice.
        cpu += 1
        _ = t.update(cpu: [7: cpu], now: t0.addingTimeInterval(302))
        reported = []
        for s in stride(from: 304, through: 500, by: 2) {
            reported += t.update(cpu: [7: cpu], now: t0.addingTimeInterval(TimeInterval(s)))
        }
        XCTAssertEqual(reported, [])
        XCTAssertEqual(t.update(cpu: [:], now: t0.addingTimeInterval(502)), [])
        XCTAssertNil(t.states[7])
    }

    func testOwnCPUTimeIsReadable() {
        XCTAssertNotNil(ProcessList.cpuSeconds(of: getpid()))
        XCTAssertNil(ProcessList.cpuSeconds(of: -3))
    }

    func testGuardStopsOnlyWhenAsked() {
        XCTAssertNil(KeepAwakeGuard(stopOnBattery: false, stopBelowPercent: 0).reason(onBattery: true, batteryPercent: 3))
        XCTAssertNil(KeepAwakeGuard(stopOnBattery: true).reason(onBattery: false, batteryPercent: 3))
        XCTAssertNotNil(KeepAwakeGuard(stopOnBattery: true).reason(onBattery: true, batteryPercent: 90))
        XCTAssertEqual(KeepAwakeGuard(stopBelowPercent: 15).reason(onBattery: true, batteryPercent: 15), "the battery is at 15%")
        XCTAssertNil(KeepAwakeGuard(stopBelowPercent: 15).reason(onBattery: true, batteryPercent: 16))
        XCTAssertNil(KeepAwakeGuard(stopBelowPercent: 15).reason(onBattery: true, batteryPercent: nil))
    }

    func testPrivacyLogIsCappedAndSurvivesBadFiles() throws {
        var log = PrivacyLog()
        for i in 0..<(PrivacyLog.maxEvents + 20) {
            log.record(PrivacyEvent(date: Date(timeIntervalSince1970: TimeInterval(i)), device: .mic, on: i % 2 == 0))
        }
        XCTAssertEqual(log.events.count, PrivacyLog.maxEvents)
        XCTAssertEqual(log.recent.first?.date, Date(timeIntervalSince1970: TimeInterval(PrivacyLog.maxEvents + 19)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("log.json")
        log.save(to: url)
        XCTAssertEqual(PrivacyLog.load(from: url).events.count, PrivacyLog.maxEvents)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(PrivacyLog.load(from: url).events, [])
        XCTAssertEqual(PrivacyLog.load(from: dir.appendingPathComponent("missing.json")).events, [])
        try? FileManager.default.removeItem(at: dir)
    }

    func testSystemLoadPercentIsBounded() {
        XCTAssertNil(SystemLoadSampler.percent(5, of: 0))
        XCTAssertEqual(SystemLoadSampler.percent(5, of: 10), 50)
        XCTAssertEqual(SystemLoadSampler.percent(50, of: 10), 100)
        var s = SystemLoadSampler()
        _ = s.sample()
        XCTAssertNotNil(s.sample().memoryPercent)
    }
}

final class SecurityTests: XCTestCase {
    func testParsesToolOutput() {
        XCTAssertEqual(SecurityCheck.firewall.parse("Firewall is enabled. (State = 1)"), .good("On"))
        XCTAssertEqual(SecurityCheck.firewall.parse("Firewall is disabled. (State = 0)"), .weak("Off"))
        XCTAssertEqual(SecurityCheck.fileVault.parse("FileVault is On.\n"), .good("On"))
        XCTAssertEqual(SecurityCheck.fileVault.parse("FileVault is Off."), .weak("Off"))
        XCTAssertEqual(SecurityCheck.gatekeeper.parse("assessments enabled"), .good("On"))
        XCTAssertEqual(SecurityCheck.gatekeeper.parse("assessments disabled"), .weak("Off"))
        XCTAssertEqual(SecurityCheck.sip.parse("System Integrity Protection status: enabled."), .good("On"))
        XCTAssertEqual(SecurityCheck.sip.parse("System Integrity Protection status: disabled."), .weak("Off"))
        XCTAssertEqual(SecurityCheck.airDrop.parse(nil), .good("Contacts only"))
        XCTAssertEqual(SecurityCheck.airDrop.parse("Everyone\n"), .weak("Everyone"))
        XCTAssertEqual(SecurityCheck.airDrop.parse("Off"), .good("Off"))
        for c in SecurityCheck.allCases where c != .airDrop {
            XCTAssertEqual(c.parse(nil), .unknown, c.rawValue)
            XCTAssertEqual(c.parse("garbage \u{0}"), .unknown, c.rawValue)
        }
    }
}

final class AutoAndHistoryTests: XCTestCase {
    func testAutoAwakeReasons() {
        XCTAssertNil(AutoAwake().reason(onBattery: false, screens: 3))
        XCTAssertEqual(AutoAwake(whilePluggedIn: true).reason(onBattery: false, screens: 1), "plugged in")
        XCTAssertNil(AutoAwake(whilePluggedIn: true).reason(onBattery: true, screens: 1))
        XCTAssertNil(AutoAwake(whilePluggedIn: true).reason(onBattery: nil, screens: 1), "unknown power never holds")
        XCTAssertEqual(AutoAwake(whileExternalDisplay: true).reason(onBattery: true, screens: 2), "external display connected")
        XCTAssertNil(AutoAwake(whileExternalDisplay: true).reason(onBattery: true, screens: 1))
    }

    func testBatteryHistoryOnePerDayCappedAndRobust() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var h = BatteryHistory()
        let d0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(h.record(health: 92, cycles: 100, on: d0, calendar: cal))
        XCTAssertFalse(h.record(health: 91, cycles: 101, on: d0.addingTimeInterval(3600), calendar: cal))
        XCTAssertFalse(h.record(health: nil, cycles: 1, on: d0.addingTimeInterval(86_400), calendar: cal))
        XCTAssertFalse(h.record(health: 0, cycles: 1, on: d0.addingTimeInterval(86_400), calendar: cal))
        XCTAssertTrue(h.record(health: 90, cycles: 110, on: d0.addingTimeInterval(86_400), calendar: cal))
        XCTAssertEqual(h.change, -2)
        for i in 2..<(BatteryHistory.maxReadings + 10) {
            h.record(health: 90, cycles: nil, on: d0.addingTimeInterval(TimeInterval(i) * 86_400), calendar: cal)
        }
        XCTAssertEqual(h.readings.count, BatteryHistory.maxReadings)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        h.save(to: url)
        XCTAssertEqual(BatteryHistory.load(from: url).readings.count, BatteryHistory.maxReadings)
        try Data("{".utf8).write(to: url)
        XCTAssertEqual(BatteryHistory.load(from: url).readings, [])
        try? FileManager.default.removeItem(at: url)
    }
}

final class TopAppsTests: XCTestCase {
    func testGroupsHelpersUnderTheirApp() {
        let rows: [(pid: Int32, path: String, bytes: UInt64)] = [
            (10, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 500),
            (11, "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", 700),
            (12, "/opt/homebrew/bin/node", 900),
            (13, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", 50),
        ]
        let apps = TopApps.group(rows, limit: 10)
        XCTAssertEqual(apps.map(\.name), ["Google Chrome", "node", "Finder"])
        XCTAssertEqual(apps.first?.bytes, 1_200)
        XCTAssertEqual(apps.first?.pids.sorted(), [10, 11])
        XCTAssertEqual(apps.last?.isSystem, true)
        XCTAssertEqual(apps[1].isSystem, false)
        XCTAssertEqual(TopApps.group(rows, limit: 1).count, 1)
        XCTAssertEqual(TopApps.group(rows, limit: -4).count, 0)
    }

    func testLiveListIsReadableAndExcludesSelf() {
        let apps = TopApps.current(limit: 50)
        XCTAssertFalse(apps.contains { $0.pids.contains(getpid()) })
        XCTAssertEqual(apps, apps.sorted { $0.bytes > $1.bytes } )
        XCTAssertEqual(TopApps.describe(bytes: UInt64.max).isEmpty, false)
    }
}

final class DemoDataTests: XCTestCase {
    /// Published pictures must never show a real user's folder or a real process.
    func testDemoDataIsSyntheticAndConsistent() {
        let now = Date()
        let sessions = DemoData.agentSessions(now: now)
        XCTAssertFalse(sessions.isEmpty)
        for s in sessions {
            XCTAssertTrue(s.folder?.hasPrefix("/Users/demo/") ?? false, "\(s)")
            XCTAssertNotNil(DemoData.activity[s.pid], "every session has an activity")
        }
        XCTAssertTrue(DemoData.activity.values.contains(.idle))
        XCTAssertTrue(DemoData.activity.values.contains(.working))
        XCTAssertEqual(Set(sessions.map(\.pid)).count, sessions.count)
        XCTAssertEqual(DemoData.privacy.micUsers.map(\.pid), [0], "no real pid to look a name up from")
        for app in DemoData.apps {
            XCTAssertTrue(app.path.hasPrefix("/Applications/") || app.path.hasPrefix("/System/Applications/"))
        }
        XCTAssertEqual(Set(DemoData.security.keys), Set(SecurityCheck.allCases))
        XCTAssertEqual(DemoData.batteryHistory(now: now).readings.count, 8)
        XCTAssertTrue(DemoData.privacyLog(now: now).events.allSatisfy { $0.date <= now })
    }
}

final class LidSuperviseTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var intent: LidModeIntent { LidModeIntent(enabled: true, since: start, expires: start.addingTimeInterval(3_600)) }

    func check(alive: Bool, sleepDisabled: Bool = true, stop: Date? = nil, at offset: TimeInterval) -> LidModeAction {
        LidModeGuard.supervise(intent: intent, systemSleepDisabled: sleepDisabled, watchdogAlive: alive,
                               stopRequestedAt: stop, now: start.addingTimeInterval(offset))
    }

    /// The real failure: sleep stayed off for hours after the watchdog vanished.
    func testDeadWatchdogWithSleepOffMustRestore() {
        XCTAssertEqual(check(alive: false, at: 120), .restore(.watchdogStopped))
        XCTAssertEqual(check(alive: false, at: 20 * 3_600), .restore(.watchdogStopped))
    }

    func testGivesTheWatchdogTimeToStart() {
        XCTAssertEqual(check(alive: false, at: 10), .none)
    }

    func testHealthySessionIsLeftAlone() {
        XCTAssertEqual(check(alive: true, at: 600), .none)
        XCTAssertEqual(check(alive: false, sleepDisabled: false, at: 600), .none, "sleep already back on")
        XCTAssertEqual(LidModeGuard.supervise(intent: .off, systemSleepDisabled: true, watchdogAlive: false,
                                              stopRequestedAt: nil, now: start), .none)
    }

    func testUnansweredStopOrDeadlineMeansTheWatchdogIsStuck() {
        let asked = start.addingTimeInterval(600)
        XCTAssertEqual(check(alive: true, stop: asked, at: 630), .none, "within one poll")
        XCTAssertEqual(check(alive: true, stop: asked, at: 700), .restore(.watchdogStopped))
        XCTAssertEqual(check(alive: true, at: 3_600 + 30), .none)
        XCTAssertEqual(check(alive: true, at: 3_600 + 120), .restore(.watchdogStopped))
    }
}

final class AwakePresetTests: XCTestCase {
    func testSavedSelectionIsCleanedUp() {
        XCTAssertEqual(AwakePreset.menuSelection(from: nil), AwakePreset.menuDefaults)
        XCTAssertEqual(AwakePreset.menuSelection(from: []), AwakePreset.menuDefaults, "never empty")
        XCTAssertEqual(AwakePreset.menuSelection(from: ["bogus", "d1", "h1", "h1"]), [.h1, .d1], "known, unique, ordered")
        XCTAssertEqual(AwakePreset.menuSelection(from: AwakePreset.allCases.map(\.rawValue)).count, AwakePreset.menuMax)
    }

    func testToggleKeepsTheSelectionValid() {
        XCTAssertEqual(AwakePreset.toggle(.m30, in: [.h1, .h3]), [.m30, .h1, .h3])
        XCTAssertEqual(AwakePreset.toggle(.h3, in: [.h1, .h3]), [.h1])
        XCTAssertEqual(AwakePreset.toggle(.h1, in: [.h1]), [.h1], "the last button can't be removed")
        let full: [AwakePreset] = [.h1, .h3, .h8, .forever]
        XCTAssertEqual(AwakePreset.toggle(.m30, in: full), full, "adding when full is refused")
    }

    func testOnlyForeverHasNoLength() {
        XCTAssertNil(AwakePreset.forever.seconds)
        XCTAssertTrue(AwakePreset.allCases.filter { $0 != .forever }.allSatisfy { ($0.seconds ?? 0) > 0 })
    }
}

final class PrivacyLogPagingTests: XCTestCase {
    func log(_ n: Int) -> PrivacyLog {
        PrivacyLog(events: (0..<n).map { PrivacyEvent(date: Date(timeIntervalSince1970: TimeInterval($0)), device: .mic, on: true) })
    }

    func testPagesAreNewestFirstAndClamped() {
        let l = log(30)
        XCTAssertEqual(l.pageCount(size: 12), 3)
        XCTAssertEqual(l.page(0, size: 12).first?.date.timeIntervalSince1970, 29)
        XCTAssertEqual(l.page(2, size: 12).count, 6)
        XCTAssertEqual(l.page(99, size: 12), l.page(2, size: 12), "past the end clamps to the last page")
        XCTAssertEqual(l.page(-5, size: 12), l.page(0, size: 12))
    }

    func testEmptyAndBadSizesNeverCrash() {
        XCTAssertEqual(log(0).pageCount(size: 12), 1)
        XCTAssertEqual(log(0).page(3, size: 12), [])
        XCTAssertEqual(log(5).page(0, size: 0), [])
        XCTAssertEqual(log(5).pageCount(size: -1), 1)
    }
}

final class SessionTitlesTests: XCTestCase {
    func testSessionIDFromArguments() {
        let id = "C1C79913-F948-4C96-90B4-E55145B36139"
        XCTAssertEqual(SessionTitles.sessionID(fromArguments: ["--session-id", id, "--agent", "claude"]), id.lowercased())
        XCTAssertEqual(SessionTitles.sessionID(fromArguments: ["--resume", id]), id.lowercased())
        XCTAssertEqual(SessionTitles.sessionID(fromArguments: ["--session-id=\(id)"]), id.lowercased())
        XCTAssertNil(SessionTitles.sessionID(fromArguments: ["--session-id"]), "missing value")
        XCTAssertNil(SessionTitles.sessionID(fromArguments: ["--session-id", "../../etc/passwd"]), "only UUIDs, never a path")
    }

    func testProjectDirName() {
        XCTAssertEqual(SessionTitles.projectDirName(for: "/Users/me/Project/external-source/pdf.craft"),
                       "-Users-me-Project-external-source-pdf-craft")
    }

    func testCustomTitleWinsAndNewestIsUsed() {
        let tail = """
        ial line cut in half","type":"ai-title"
        {"type":"ai-title","aiTitle":"first-guess"}
        {"type":"user","message":"hi"}
        {"type":"ai-title","aiTitle":"fix-login-redirect"}
        """
        XCTAssertEqual(SessionTitles.title(inTranscriptTail: tail[...]), "fix login redirect")
        let renamed = tail + "\n{\"type\":\"custom-title\",\"customTitle\":\"Checkout bug\"}\n{\"type\":\"ai-title\",\"aiTitle\":\"later\"}"
        XCTAssertEqual(SessionTitles.title(inTranscriptTail: renamed[...]), "Checkout bug")
        XCTAssertNil(SessionTitles.title(inTranscriptTail: "{\"type\":\"user\"}"[...]))
    }

    func testReadsTitleFromDiskAndOnlyGuessesWhenUnambiguous() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kw-titles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/demo/code/api"
        let dir = root.appendingPathComponent(SessionTitles.projectDirName(for: cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        try "{\"type\":\"ai-title\",\"aiTitle\":\"with-an-id\"}\n".write(to: dir.appendingPathComponent("\(a).jsonl"), atomically: true, encoding: .utf8)
        try "{\"type\":\"ai-title\",\"aiTitle\":\"interactive\"}\n".write(to: dir.appendingPathComponent("\(b).jsonl"), atomically: true, encoding: .utf8)
        let withID = AgentSession(pid: 1, agent: "Claude Code", folder: cwd, sessionID: a)
        let plain = AgentSession(pid: 2, agent: "Claude Code", folder: cwd)
        XCTAssertEqual(SessionTitles.titles(for: [withID, plain], projectsDir: root), [1: "with an id", 2: "interactive"])
        let plain2 = AgentSession(pid: 3, agent: "Claude Code", folder: cwd)
        XCTAssertEqual(SessionTitles.titles(for: [withID, plain, plain2], projectsDir: root), [1: "with an id"],
                       "two id-less sessions in one folder: no guessing")
        XCTAssertEqual(SessionTitles.titles(for: [AgentSession(pid: 4, agent: "Codex", folder: cwd)], projectsDir: root), [:])
    }
}

final class UpdateCheckTests: XCTestCase {
    func json(_ tag: String, _ url: String) -> Data { Data("{\"tag_name\":\"\(tag)\",\"html_url\":\"\(url)\"}".utf8) }

    func testParsesOnlyGitHubPagesAndVersionTags() {
        let ok = UpdateCheck.parse(json("v0.3.0", "https://github.com/AgentSkillDeck/keepwatch/releases/tag/v0.3.0"))
        XCTAssertEqual(ok?.version, "0.3.0")
        XCTAssertNil(UpdateCheck.parse(json("v0.3.0", "https://evil.example/keepwatch")), "never send the user off GitHub")
        XCTAssertNil(UpdateCheck.parse(json("v0.3.0", "http://github.com/x")), "https only")
        XCTAssertNil(UpdateCheck.parse(json("latest; rm -rf", "https://github.com/x")))
        XCTAssertNil(UpdateCheck.parse(Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(count: 300 * 1024)), "oversized responses are ignored")
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.9"), "numeric, not text")
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.99.1"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2.0", than: "0.2"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("garbage", than: "0.2.0"))
    }

    func testDueOncePerDay() {
        let now = Date()
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(86_400 * 30), now: now), "a clock set back can't block checks")
    }
}

final class StayActiveTests: XCTestCase {
    func nudge(enabled: Bool = true, trusted: Bool = true, lid: Bool = false, idle: TimeInterval?, minutes: Int = 4) -> Bool {
        StayActive.shouldNudge(enabled: enabled, trusted: trusted, lidSession: lid, idleSeconds: idle, idleMinutes: minutes)
    }

    func testNudgesOnlyAfterTheIdleLimit() {
        XCTAssertFalse(nudge(idle: 239))
        XCTAssertTrue(nudge(idle: 240))
        XCTAssertTrue(nudge(idle: 130, minutes: 2))
    }

    func testNeverWhenOffUntrustedUnknownOrLidClosed() {
        XCTAssertFalse(nudge(enabled: false, idle: 999))
        XCTAssertFalse(nudge(trusted: false, idle: 999))
        XCTAssertFalse(nudge(idle: nil))
        XCTAssertFalse(nudge(idle: .infinity))
        XCTAssertFalse(nudge(lid: true, idle: 999), "a closed laptop must not look active")
    }

    func testOutOfRangeMinutesAreClamped() {
        XCTAssertFalse(nudge(idle: 30, minutes: 0), "0 becomes 1 minute, not every tick")
        XCTAssertFalse(nudge(idle: 3_000, minutes: 10_000), "capped at an hour")
        XCTAssertTrue(nudge(idle: 3_600, minutes: 10_000))
    }

    func testIdleTimeIsReadable() {
        XCTAssertNotNil(StayActive.idleSeconds())
    }
}

final class VersionSyncTests: XCTestCase {
    /// The CLI prints its own version (Homebrew's test checks it); it must match the app's.
    func testCLIVersionMatchesInfoPlist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist")))
        let app = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
        let main = try String(contentsOf: root.appendingPathComponent("Sources/KeepwatchCLI/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("let version = \"\(app)\""), "Sources/KeepwatchCLI/main.swift version must be \(app)")
        let formula = try String(contentsOf: root.appendingPathComponent("packaging/homebrew/keepwatch-cli.rb"), encoding: .utf8)
        XCTAssertTrue(formula.contains("v\(app)/keepwatch-cli-\(app)-macos.zip"), "Homebrew formula URL must be \(app)")
    }
}

final class ScreenshotToolbarTests: XCTestCase {
    let laptop = CGRect(x: 0, y: 0, width: 1280, height: 832)

    func testParsesSavedPoint() {
        XCTAssertEqual(ScreenshotToolbar.parse("{735, -12}"), CGPoint(x: 735, y: -12))
        XCTAssertNil(ScreenshotToolbar.parse("{735}"))
        XCTAssertNil(ScreenshotToolbar.parse("{nan, 1}"))
        XCTAssertNil(ScreenshotToolbar.parse("junk"))
    }

    func testOffScreenSpots() {
        XCTAssertTrue(ScreenshotToolbar.isOffScreen(origin: CGPoint(x: 735, y: -12), screens: [laptop]), "below the bottom edge")
        XCTAssertTrue(ScreenshotToolbar.isOffScreen(origin: CGPoint(x: 1000, y: 100), screens: [laptop]), "past the right edge")
        XCTAssertTrue(ScreenshotToolbar.isOffScreen(origin: CGPoint(x: 2000, y: 100), screens: [laptop]), "an unplugged display")
        XCTAssertFalse(ScreenshotToolbar.isOffScreen(origin: CGPoint(x: 440, y: 40), screens: [laptop]))
        XCTAssertFalse(ScreenshotToolbar.isOffScreen(origin: CGPoint(x: 1400, y: 100),
                                                     screens: [laptop, CGRect(x: 1280, y: 0, width: 1920, height: 1080)]))
    }
}

final class MenuSectionTests: XCTestCase {
    func testSelectionIsCleanedAndOrdered() {
        XCTAssertEqual(MenuSection.selection(from: nil), MenuSection.defaults)
        XCTAssertEqual(MenuSection.selection(from: ["memory", "privacy", "bogus", "privacy"]), [.privacy, .memory])
        XCTAssertEqual(MenuSection.selection(from: []), [], "an empty menu is allowed")
    }

    func testToggle() {
        XCTAssertEqual(MenuSection.toggle(.agents, in: MenuSection.defaults), [.privacy, .keepAwake, .laptopClosed, .agents])
        XCTAssertEqual(MenuSection.toggle(.privacy, in: [.privacy, .memory]), [.memory])
    }
}

final class HostAppTests: XCTestCase {
    func testWalksUpToTheNearestApp() {
        let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 200]
        let chain = HostApp.ancestors(of: 500, parent: { parents[$0] })
        XCTAssertEqual(chain, [400, 300, 200])
        XCTAssertEqual(HostApp.host(of: 500, parent: { parents[$0] }, isApp: { $0 == 300 || $0 == 200 }), 300)
        XCTAssertNil(HostApp.host(of: 500, parent: { parents[$0] }, isApp: { _ in false }))
    }

    func testCyclesAndDepthAreBounded() {
        XCTAssertEqual(HostApp.ancestors(of: 1, parent: { $0 == 1 ? 2 : 1 }), [2], "a cycle stops")
        XCTAssertEqual(HostApp.ancestors(of: 1, parent: { $0 + 1 }).count, HostApp.maxDepth)
    }

    func testRealParentOfThisProcess() {
        XCTAssertEqual(HostApp.parentPID(of: getpid()), getppid() > 1 ? getppid() : nil)
        XCTAssertNil(HostApp.parentPID(of: -5))
    }
}

final class AwayLogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSummarisesALongAbsence() {
        var log = AwayLog()
        log.leave(at: t0, battery: 82)
        log.record(.init(date: t0.addingTimeInterval(600), icon: "checkmark", text: "Claude Code finished"))
        let s = log.comeBack(at: t0.addingTimeInterval(7_800), battery: 61)
        XCTAssertEqual(s?.duration, 7_800)
        XCTAssertEqual(s?.events.map(\.text), ["Claude Code finished"])
        XCTAssertEqual(s?.batteryUsed, 21)
        XCTAssertFalse(log.isAway)
    }

    func testShortQuietAbsenceIsSkipped() {
        var log = AwayLog()
        log.leave(at: t0, battery: 50)
        XCTAssertNil(log.comeBack(at: t0.addingTimeInterval(120), battery: 50))
    }

    func testShortAbsenceWithEventsIsReported() {
        var log = AwayLog()
        log.leave(at: t0, battery: nil)
        log.record(.init(date: t0, icon: "x", text: "Lid session ended"))
        XCTAssertNotNil(log.comeBack(at: t0.addingTimeInterval(60), battery: nil))
    }

    func testEventsOnlyWhileAwayAndCharging() {
        var log = AwayLog()
        log.record(.init(date: t0, icon: "x", text: "ignored"))
        log.leave(at: t0, battery: 40)
        log.leave(at: t0.addingTimeInterval(500), battery: 10) // a second "leave" doesn't restart it
        let s = log.comeBack(at: t0.addingTimeInterval(3_600), battery: 70)
        XCTAssertEqual(s?.events, [])
        XCTAssertNil(s?.batteryUsed, "charged while away")
        XCTAssertEqual(s?.start, t0)
        XCTAssertNil(log.comeBack(at: t0, battery: 1), "not away")
    }

    func testClockGoingBackwardsIsIgnored() {
        var log = AwayLog()
        log.leave(at: t0, battery: 1)
        XCTAssertNil(log.comeBack(at: t0.addingTimeInterval(-50), battery: 1))
    }
}

final class AuditLogTests: XCTestCase {
    func testAppendCleansAndCaps() {
        var log = AuditLog()
        log.append("Quit app", "Evil\nName\u{1b}[31m")
        XCTAssertEqual(log.entries.last?.detail, "Evil Name [31m", "no line breaks or escapes")
        log.append("x", String(repeating: "a", count: 1_000))
        XCTAssertEqual(log.entries.last?.detail.count, AuditLog.maxTextLength)
        for i in 0..<(AuditLog.maxEntries + 5) { log.append("n", "\(i)") }
        XCTAssertEqual(log.entries.count, AuditLog.maxEntries)
        XCTAssertEqual(log.entries.last?.detail, "\(AuditLog.maxEntries + 4)", "oldest dropped first")
    }

    func testPagingNewestFirst() {
        var log = AuditLog()
        for i in 0..<25 { log.append("n", "\(i)", at: Date(timeIntervalSince1970: TimeInterval(i))) }
        XCTAssertEqual(log.page(0, size: 10).first?.detail, "24")
        XCTAssertEqual(log.page(2, size: 10).count, 5)
        XCTAssertEqual(log.page(9, size: 10), log.page(2, size: 10))
        XCTAssertEqual(log.pageCount(size: 10), 3)
        XCTAssertEqual(AuditLog().page(0, size: 10), [])
        XCTAssertEqual(log.page(0, size: 0), [])
    }

    func testSaveLoadIsPrivateAndLenient() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kwa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")
        var log = AuditLog()
        log.append("Lid session started", "sleep after 3 h", at: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(log.save(to: url))
        XCTAssertEqual(AuditLog.load(from: url), log)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(AuditLog.load(from: url), AuditLog())
        XCTAssertEqual(AuditLog.load(from: dir.appendingPathComponent("missing.json")), AuditLog())
        XCTAssertTrue(log.text().hasSuffix("Lid session started: sleep after 3 h"))
    }
}

final class PrivacyUsageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testPairsOnAndOffPerApp() {
        let log = PrivacyLog(events: [
            PrivacyEvent(date: t0, device: .mic, on: true, apps: ["Zoom"]),
            PrivacyEvent(date: t0.addingTimeInterval(600), device: .mic, on: false),
            PrivacyEvent(date: t0.addingTimeInterval(700), device: .mic, on: true, apps: ["Zoom"]),
            PrivacyEvent(date: t0.addingTimeInterval(1_000), device: .mic, on: false),
            PrivacyEvent(date: t0.addingTimeInterval(100), device: .camera, on: true),
            PrivacyEvent(date: t0.addingTimeInterval(160), device: .camera, on: false),
        ])
        let u = log.usage(since: t0, now: t0.addingTimeInterval(2_000))
        XCTAssertEqual(u.first, PrivacyUsage(app: "Zoom", device: .mic, sessions: 2, seconds: 900))
        XCTAssertEqual(u.last, PrivacyUsage(app: PrivacyUsage.unknownCamera, device: .camera, sessions: 1, seconds: 60))
    }

    func testStillOnCountsToNowAndOldTimeIsCut() {
        let log = PrivacyLog(events: [
            PrivacyEvent(date: t0, device: .mic, on: true, apps: ["FaceTime"]),
            PrivacyEvent(date: t0.addingTimeInterval(-5_000), device: .camera, on: true),
            PrivacyEvent(date: t0.addingTimeInterval(-4_000), device: .camera, on: false),
        ])
        let u = log.usage(since: t0.addingTimeInterval(-100), now: t0.addingTimeInterval(300))
        XCTAssertEqual(u, [PrivacyUsage(app: "FaceTime", device: .mic, sessions: 1, seconds: 300)], "camera use ended before `since`")
    }

    func testOffWithoutOnAndEmptyLog() {
        XCTAssertEqual(PrivacyLog().usage(since: t0, now: t0), [])
        let log = PrivacyLog(events: [PrivacyEvent(date: t0, device: .mic, on: false)])
        XCTAssertEqual(log.usage(since: .distantPast, now: t0), [])
    }
}

final class ScreenWatchTests: XCTestCase {
    func testWatchers() {
        XCTAssertEqual(ScreenWatch.watchers(processNames: ["Finder", "replayd"]), [], "replayd always runs; not a signal")
        XCTAssertEqual(ScreenWatch.watchers(processNames: ["screensharingd"]), [.remoteViewer])
        XCTAssertEqual(ScreenWatch.watchers(processNames: ["screencapture"]), [], "your own screenshot isn't a warning")
    }
}

final class CodexTitleTests: XCTestCase {
    func testNamesARunningCodexSessionFromItsRolloutAndIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kwc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: now)
        let day = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = "01a0e184-3cef-78f2-a3d4-6950a4b03535"
        try Data(#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/app"}}"#.utf8 + Data("\n{}\n".utf8))
            .write(to: day.appendingPathComponent("rollout-x-\(id).jsonl"))
        try Data(#"""
        {"id":"\#(id)","thread_name":"Old name"}
        {"id":"\#(id)","thread_name":"Fix the login page"}
        {"id":"other","thread_name":"Something else"}
        """#.utf8).write(to: root.appendingPathComponent("session_index.jsonl"))
        let running = AgentSession(pid: 7, agent: "Codex", folder: "/work/app", started: now.addingTimeInterval(-60))
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        XCTAssertEqual(SessionTitles.titles(for: [running], projectsDir: empty, codexDir: root, now: now), [7: "Fix the login page"])
        let elsewhere = AgentSession(pid: 8, agent: "Codex", folder: "/work/other", started: now.addingTimeInterval(-60))
        XCTAssertEqual(SessionTitles.titles(for: [elsewhere], projectsDir: empty, codexDir: root, now: now), [:], "no file for that folder")
        let twin = AgentSession(pid: 9, agent: "Codex", folder: "/work/app", started: now.addingTimeInterval(-30))
        XCTAssertEqual(SessionTitles.titles(for: [running, twin], projectsDir: empty, codexDir: root, now: now), [:],
                       "two sessions in one folder: no guessing")
        let resumed = AgentSession(pid: 10, agent: "Codex", folder: "/x", sessionID: id)
        XCTAssertEqual(SessionTitles.titles(for: [resumed], projectsDir: empty, codexDir: root, now: now), [10: "Fix the login page"])
        XCTAssertEqual(SessionTitles.sessionID(fromArguments: ["resume", id]), id)
    }
}
