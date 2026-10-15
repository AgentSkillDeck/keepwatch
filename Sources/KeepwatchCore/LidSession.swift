import Foundation

/// A lid-closed session: how long the Mac may run with the lid shut and when
/// it must go back to sleep.
///
/// Turning sleep off needs root, and once the lid is closed nobody can type a
/// password to turn it back on. So starting a session runs ONE admin command
/// that disables sleep and launches a small root watchdog (a fixed shell loop
/// built here). The watchdog alone decides when to restore sleep, so the Mac
/// goes back to sleep on schedule even if Keepwatch crashes or is quit.
public struct LidSessionPlan: Equatable, Codable, Sendable {
    /// Restore sleep this long after the lid closes (accumulates only while
    /// closed; opening the lid resets it). nil = no lid-closed limit.
    public var afterLidClosed: TimeInterval?
    /// Restore sleep at this absolute time (e.g. "tonight at 1:00").
    public var sleepAt: Date?
    /// Allow the session on battery. Off by default (see LidModePolicy).
    public var allowOnBattery: Bool
    /// When allowed on battery, restore sleep at or below this percentage.
    public var minBatteryPercent: Int
    /// Put the Mac to sleep immediately after restoring, if the lid is closed.
    public var sleepWhenDone: Bool

    /// Absolute ceiling for any session, whatever the plan says.
    public static let hardCap: TimeInterval = 12 * 3600

    public init(afterLidClosed: TimeInterval? = 3 * 3600, sleepAt: Date? = nil, allowOnBattery: Bool = false,
                minBatteryPercent: Int = 20, sleepWhenDone: Bool = true) {
        self.afterLidClosed = afterLidClosed
        self.sleepAt = sleepAt
        self.allowOnBattery = allowOnBattery
        self.minBatteryPercent = minBatteryPercent
        self.sleepWhenDone = sleepWhenDone
    }

    /// The next occurrence of hour:minute after `now`, in the given calendar.
    public static func nextTime(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime)
    }
}

public enum LidWatchdog {
    /// Where the app and the CLI drop the stop file. Shared so `keepwatch lid end`
    /// works with or without the app running.
    public static func defaultStopFile() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let dir = caches.appendingPathComponent("Keepwatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lid-session.stop")
    }


    public enum BuildError: Error, Equatable {
        case unsafeStopPath
        case nothingToDo
    }

    /// The watchdog's overall deadline in whole seconds from start: the
    /// earliest of sleepAt and the hard cap.
    public static func deadlineSeconds(_ plan: LidSessionPlan, now: Date) -> Int {
        var limit = LidSessionPlan.hardCap
        if let at = plan.sleepAt { limit = min(limit, max(60, at.timeIntervalSince(now))) }
        return Int(limit.rounded(.down))
    }

    /// Builds the admin shell command that disables sleep and starts the
    /// watchdog. Every interpolated value is a number or a vetted path, so no
    /// user text reaches the root shell.
    ///
    /// The watchdog checks every 30 s and restores sleep when any of these is true:
    /// the deadline passed; the lid has been closed for `afterLidClosed`;
    /// the stop file exists (Keepwatch asks: agents done, too hot, user stop);
    /// on battery when not allowed, or battery at/below the floor.
    public static func startCommand(plan: LidSessionPlan, stopFile: String, now: Date) throws -> String {
        try startCommand(plan: plan, stopFile: stopFile, now: now, tools: .system)
    }

    /// Paths of the binaries the watchdog calls; replaced by stubs in tests so
    /// the real shell loop can be exercised without root.
    struct Tools {
        var pmset = "/usr/bin/pmset"
        var ioreg = "/usr/sbin/ioreg"
        var interval = 30
        /// Floor for the lid-closed limit; tests lower it to run in seconds.
        var minLidSeconds = 60
        static let system = Tools()
    }

    static func startCommand(plan: LidSessionPlan, stopFile: String, now: Date, tools: Tools) throws -> String {
        guard stopFile.hasPrefix("/"), !stopFile.contains("'"), !stopFile.contains("\n"),
              !stopFile.contains("\\"), stopFile.count < 512 else { throw BuildError.unsafeStopPath }
        let deadline = deadlineSeconds(plan, now: now)
        guard deadline > 0 else { throw BuildError.nothingToDo }
        let lidLimit = plan.afterLidClosed.map { max(tools.minLidSeconds, Int($0.rounded(.down))) } ?? 0
        let minBattery = max(0, min(100, plan.minBatteryPercent))
        let allowBattery = plan.allowOnBattery ? 1 : 0
        let sleepAfter = plan.sleepWhenDone ? 1 : 0

        // POSIX sh, run as root by `do shell script ... with administrator privileges`.
        // Detached with nohup so the admin call returns at once.
        let loop = """
        S='\(stopFile)'; END=$(( $(date +%s) + \(deadline) )); LIDMAX=\(lidLimit); CLOSED=0; \
        while :; do \
        NOW=$(date +%s); [ "$NOW" -ge "$END" ] && break; [ -e "$S" ] && break; \
        B=$(\(tools.pmset) -g batt); \
        if echo "$B" | /usr/bin/grep -q "Battery Power"; then \
        [ \(allowBattery) -eq 0 ] && break; \
        P=$(echo "$B" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -1 | /usr/bin/tr -d '%'); \
        [ -n "$P" ] && [ "$P" -le \(minBattery) ] && break; fi; \
        if [ "$LIDMAX" -gt 0 ]; then \
        if \(tools.ioreg) -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes'; \
        then CLOSED=$((CLOSED + \(tools.interval))); else CLOSED=0; fi; \
        [ "$CLOSED" -ge "$LIDMAX" ] && break; fi; \
        sleep \(tools.interval); done; \
        \(tools.pmset) -a disablesleep 0; /bin/rm -f "$S"; \
        if [ \(sleepAfter) -eq 1 ] && \(tools.ioreg) -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes'; \
        then \(tools.pmset) sleepnow; fi
        """
        let escaped = loop.replacingOccurrences(of: "'", with: #"'\''"#)
        return "/bin/rm -f '\(stopFile)'; \(tools.pmset) -a disablesleep 1 && " +
            "/usr/bin/nohup /bin/sh -c '\(escaped)' >/dev/null 2>&1 &"
    }

    /// The command to end a session right now (also needs admin). Normally
    /// Keepwatch just creates the stop file and lets the watchdog do this.
    public static func stopNowCommand() -> String { PMSet.disableSleepCommand(false) }
}
