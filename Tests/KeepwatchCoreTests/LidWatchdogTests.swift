import XCTest
@testable import KeepwatchCore

/// Runs the real watchdog shell loop as the current user, as a launchd job in
/// the user's own domain, with `pmset` and `ioreg` replaced by stubs that
/// record calls. Nothing touches real settings.
final class LidWatchdogTests: XCTestCase {
    var dir: URL!
    var log: URL { dir.appendingPathComponent("calls.log") }
    var stop: URL { dir.appendingPathComponent("lid.stop") }
    let label = "app.keepwatch.test-watchdog.\(UUID().uuidString)"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // State files the stubs read: power source + percentage, and lid state.
        try "AC Power".write(to: dir.appendingPathComponent("power"), atomically: true, encoding: .utf8)
        try "80".write(to: dir.appendingPathComponent("pct"), atomically: true, encoding: .utf8)
        try "Yes".write(to: dir.appendingPathComponent("lid"), atomically: true, encoding: .utf8)
        try stub("pmset", """
        if [ "$1" = "-g" ] && [ "$2" = "batt" ]; then echo "Now drawing from '$(cat \(dir.path)/power)'"; \
        echo " -InternalBattery-0 (id=1)	$(cat \(dir.path)/pct)%; discharging; present: true"; \
        elif [ "$1" = "-g" ]; then printf ' SleepDisabled\\t\\t%s\\n' "$(cat \(dir.path)/disabled 2>/dev/null || echo 0)"; \
        else echo "$*" >> \(log.path); \
        [ "$2" = "disablesleep" ] && echo "$3" > \(dir.path)/disabled; fi
        """)
        try stub("ioreg", #"echo "  | \"AppleClamshellState\" = $(cat \#(dir.path)/lid)""#)
    }

    override func tearDownWithError() throws {
        _ = run("/bin/launchctl", ["remove", label])
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    var jobLoaded: Bool { run("/bin/launchctl", ["list", label]) == 0 }

    func stub(_ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var tools: LidWatchdog.Tools {
        LidWatchdog.Tools(pmset: dir.appendingPathComponent("pmset").path,
                          ioreg: dir.appendingPathComponent("ioreg").path,
                          logFile: dir.appendingPathComponent("watchdog.log").path, label: label, interval: 1, poll: 1, minLidSeconds: 1)
    }

    func start(_ plan: LidSessionPlan) throws {
        let cmd = try LidWatchdog.startCommand(plan: plan, stopFile: stop.path, now: Date(), tools: tools)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func calls(waitingFor last: String, timeout: TimeInterval = 15) -> [String] {
        let end = Date().addingTimeInterval(timeout)
        var lines: [String] = []
        repeat {
            lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if lines.last == last { return lines }
            usleep(200_000)
        } while Date() < end
        return lines
    }

    func testRestoresAfterLidClosedLimitAndSleeps() throws {
        try start(LidSessionPlan(afterLidClosed: 2))
        XCTAssertEqual(calls(waitingFor: "sleepnow"), ["-a disablesleep 1", "-a disablesleep 0", "sleepnow"])
    }

    func testStopFileEndsSessionAndIsRemoved() throws {
        try start(LidSessionPlan(afterLidClosed: nil))
        try "x".write(to: stop, atomically: true, encoding: .utf8)
        XCTAssertEqual(calls(waitingFor: "sleepnow"), ["-a disablesleep 1", "-a disablesleep 0", "sleepnow"])
        usleep(300_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stop.path))
    }

    func testBatteryNotAllowedRestoresWithoutSleepingWhenLidOpen() throws {
        try "Battery Power".write(to: dir.appendingPathComponent("power"), atomically: true, encoding: .utf8)
        try "No".write(to: dir.appendingPathComponent("lid"), atomically: true, encoding: .utf8)
        try start(LidSessionPlan(afterLidClosed: nil))
        XCTAssertEqual(calls(waitingFor: "-a disablesleep 0"), ["-a disablesleep 1", "-a disablesleep 0"])
    }

    func testBatteryFloorWhenBatteryAllowed() throws {
        try "Battery Power".write(to: dir.appendingPathComponent("power"), atomically: true, encoding: .utf8)
        try start(LidSessionPlan(afterLidClosed: nil, allowOnBattery: true, minBatteryPercent: 20))
        usleep(2_500_000)
        XCTAssertEqual(calls(waitingFor: "never", timeout: 0.1), ["-a disablesleep 1"], "80% > floor: keep running")
        try "19".write(to: dir.appendingPathComponent("pct"), atomically: true, encoding: .utf8)
        XCTAssertEqual(calls(waitingFor: "sleepnow"), ["-a disablesleep 1", "-a disablesleep 0", "sleepnow"])
    }

    func testOpeningTheLidResetsTheClosedTimer() throws {
        try start(LidSessionPlan(afterLidClosed: 3))
        usleep(1_500_000)
        try "No".write(to: dir.appendingPathComponent("lid"), atomically: true, encoding: .utf8)
        usleep(2_500_000)
        try "Yes".write(to: dir.appendingPathComponent("lid"), atomically: true, encoding: .utf8)
        usleep(1_500_000)
        XCTAssertEqual(calls(waitingFor: "never", timeout: 0.1), ["-a disablesleep 1"], "timer restarted on reopen")
        XCTAssertEqual(calls(waitingFor: "sleepnow"), ["-a disablesleep 1", "-a disablesleep 0", "sleepnow"])
    }

    /// The real app wraps the command in AppleScript `do shell script`. Run
    /// the same escaping through osascript (as the user, not admin): it must
    /// return at once while a long session keeps running, and the watchdog
    /// must not belong to osascript. (The old background-child watchdog kept
    /// osascript waiting for the whole session; a short session hid that.)
    func testAppleScriptReturnsAtOnceAndWatchdogOutlivesIt() throws {
        let cmd = try LidWatchdog.startCommand(plan: LidSessionPlan(afterLidClosed: nil), stopFile: stop.path, now: Date(), tools: tools)
        let script = PMSet.appleScript(for: cmd, prompt: "test \"quoted\" prompt", admin: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = Pipe()
        let started = Date()
        try p.run()
        while p.isRunning, Date().timeIntervalSince(started) < 8 { usleep(100_000) }
        let stillRunning = p.isRunning
        if stillRunning { p.terminate() }
        XCTAssertFalse(stillRunning, "osascript must not wait for the watchdog")
        XCTAssertEqual(p.terminationStatus, 0)
        usleep(2_500_000)
        XCTAssertTrue(jobLoaded, "watchdog runs as its own launchd job")
        XCTAssertEqual(calls(waitingFor: "never", timeout: 0.1), ["-a disablesleep 1"], "still supervising")
        try "x".write(to: stop, atomically: true, encoding: .utf8)
        XCTAssertEqual(calls(waitingFor: "sleepnow"), ["-a disablesleep 1", "-a disablesleep 0", "sleepnow"])
        usleep(300_000)
        let log = (try? String(contentsOf: dir.appendingPathComponent("watchdog.log"), encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains(" started\n") && log.hasSuffix(" ended: stop-requested\n"), log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stop.path + ".log"), "root writes nothing in the user's folders")
    }

    /// The loop removes its own job when done, so launchd doesn't restart it.
    func testJobRemovesItselfWhenDone() throws {
        try start(LidSessionPlan(afterLidClosed: 2))
        XCTAssertEqual(calls(waitingFor: "sleepnow"), ["-a disablesleep 1", "-a disablesleep 0", "sleepnow"])
        let end = Date().addingTimeInterval(5)
        while jobLoaded, Date() < end { usleep(200_000) }
        XCTAssertFalse(jobLoaded)
    }

    /// A copy launchd restarts after sleep is already back on does nothing.
    func testRestartedCopyExitsWhenSleepIsOn() throws {
        let cmd = try LidWatchdog.startCommand(plan: LidSessionPlan(afterLidClosed: 2), stopFile: stop.path, now: Date(), tools: tools)
        // Same job, but without the leading "disablesleep 1": sleep is on.
        let submit = try XCTUnwrap(cmd.range(of: "/bin/launchctl submit")).lowerBound
        XCTAssertEqual(run("/bin/sh", ["-c", String(cmd[submit...])]), 0)
        let end = Date().addingTimeInterval(5)
        repeat { usleep(300_000) } while jobLoaded && Date() < end
        XCTAssertFalse(jobLoaded)
        XCTAssertEqual(calls(waitingFor: "never", timeout: 0.1), [], "never touched sleep")
    }

    /// End must take seconds even though battery and lid checks run every
    /// 30 s; a slow End made people reach for the password fallback.
    func testStopIsSeenWithinAPollNotAnInterval() throws {
        var slow = tools
        slow.interval = 30
        let cmd = try LidWatchdog.startCommand(plan: LidSessionPlan(afterLidClosed: nil), stopFile: stop.path, now: Date(), tools: slow)
        XCTAssertEqual(run("/bin/sh", ["-c", cmd]), 0)
        usleep(1_500_000)
        try "x".write(to: stop, atomically: true, encoding: .utf8)
        let asked = Date()
        XCTAssertEqual(calls(waitingFor: "sleepnow", timeout: 6), ["-a disablesleep 1", "-a disablesleep 0", "sleepnow"])
        XCTAssertLessThan(Date().timeIntervalSince(asked), 4)
    }

    func testStopNowAlsoRemovesTheJob() {
        XCTAssertTrue(LidWatchdog.stopNowCommand().hasPrefix("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertTrue(LidWatchdog.stopNowCommand().contains("/bin/launchctl remove \(LidWatchdog.label)"))
    }

    func testRejectsUnsafeStopPaths() {
        for bad in ["relative/path", "/tmp/it's", "/tmp/a\nb", "/tmp/a\\b"] {
            XCTAssertThrowsError(try LidWatchdog.startCommand(plan: .init(), stopFile: bad, now: Date()), bad)
        }
    }

    func testDeadlineIsCappedAndScheduled() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(LidWatchdog.deadlineSeconds(.init(), now: now), 12 * 3600)
        XCTAssertEqual(LidWatchdog.deadlineSeconds(.init(sleepAt: now.addingTimeInterval(7200)), now: now), 7200)
        XCTAssertEqual(LidWatchdog.deadlineSeconds(.init(sleepAt: now.addingTimeInterval(99 * 3600)), now: now), 12 * 3600)
        XCTAssertEqual(LidWatchdog.deadlineSeconds(.init(sleepAt: now.addingTimeInterval(-50)), now: now), 60)
    }

    func testRealCommandUsesSystemBinaries() throws {
        let cmd = try LidWatchdog.startCommand(plan: .init(), stopFile: "/tmp/kw.stop", now: Date())
        XCTAssertTrue(cmd.contains("/usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 || exit 1; " +
                                   "/bin/launchctl submit -l \(LidWatchdog.label) -- /bin/sh -c"))
        XCTAssertTrue(cmd.contains("/usr/sbin/ioreg -r -k AppleClamshellState"))
        XCTAssertTrue(cmd.contains("then T=30;"), "battery and lid every 30 s")
        XCTAssertTrue(cmd.contains("/bin/sleep 2; T=$((T - 2)); done"), "stop file every 2 s")
        XCTAssertTrue(cmd.contains("/var/log/keepwatch-lid.log"), "log only in a root-owned folder")
    }

    func testNextTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 3600 * 22) // 22:00 UTC
        XCTAssertEqual(LidSessionPlan.nextTime(hour: 1, minute: 0, after: now, calendar: cal),
                       Date(timeIntervalSince1970: 3600 * 25))
        XCTAssertNil(LidSessionPlan.nextTime(hour: 24, minute: 0, after: now, calendar: cal))
    }
}
