import Foundation

/// Made-up data for screenshots and the README video
/// (`Keepwatch --render-snapshots DIR --demo`), so they show no one's real
/// apps, folders or ports. Nothing here is read from or written to the Mac.
public enum DemoData {
    public static func agentSessions(now: Date) -> [AgentSession] {
        [
            AgentSession(pid: 41_201, agent: "Claude Code", folder: "/Users/demo/code/website", started: now.addingTimeInterval(-52 * 60)),
            AgentSession(pid: 41_377, agent: "Claude Code", folder: "/Users/demo/code/api", started: now.addingTimeInterval(-18 * 60)),
            AgentSession(pid: 42_010, agent: "Codex", folder: "/Users/demo/code/mobile-app", started: now.addingTimeInterval(-7 * 60)),
            AgentSession(pid: 42_455, agent: "Gemini CLI", folder: "/Users/demo/code/docs", started: now.addingTimeInterval(-3 * 60)),
        ]
    }

    /// Session names, as Claude Code titles them.
    public static let titles: [Int32: String] = [41_201: "Fix the checkout redirect", 41_377: "Add rate limits to the API"]

    /// Session pid → working or idle; one is idle so both states show.
    public static let activity: [Int32: AgentActivity] = [41_201: .working, 41_377: .idle, 42_010: .working, 42_455: .working]

    /// Mic and camera both in use, so the LIVE states show. The mic user has
    /// no pid, so its name comes from `bundleID` and never from a real process.
    public static let privacy = PrivacySnapshot(micInUse: true, cameraInUse: true,
                                                micUsers: [MicUser(pid: 0, bundleID: "FaceTime")], micMuted: false)

    public static let power = PowerState(batteryPercent: 82, onBattery: false, charging: true, minutesRemaining: nil,
                                         cycleCount: 214, healthPercent: 94, lidClosed: false, thermal: .nominal,
                                         lowPowerMode: false)

    public static let pmset = PMSet.Settings(sleepDisabled: false, lowPowerMode: false, sleepMinutes: 10,
                                             displaySleepMinutes: 5, sleepPreventedBy: ["Keepwatch"])

    public static let load = SystemLoad(cpuPercent: 23, memoryPercent: 61)

    public static let ports: [ListeningPort] = [
        ListeningPort(port: 3000, address: "127.0.0.1", pid: 43_100, process: "node"),
        ListeningPort(port: 5432, address: "127.0.0.1", pid: 43_150, process: "postgres"),
        ListeningPort(port: 8080, address: "*", pid: 43_210, process: "python3"),
    ]

    /// Apps that ship with macOS, so their icons are public and always present.
    public static let apps: [AppUsage] = [
        AppUsage(name: "Safari", path: "/Applications/Safari.app", pids: [44_001], bytes: 1_610_612_736, isSystem: false),
        AppUsage(name: "Xcode", path: "/Applications/Xcode.app", pids: [44_002], bytes: 1_181_116_006, isSystem: false),
        AppUsage(name: "Music", path: "/System/Applications/Music.app", pids: [44_003], bytes: 412_316_860, isSystem: false),
        AppUsage(name: "Notes", path: "/System/Applications/Notes.app", pids: [44_004], bytes: 268_435_456, isSystem: false),
        AppUsage(name: "Maps", path: "/System/Applications/Maps.app", pids: [44_005], bytes: 188_743_680, isSystem: false),
    ]

    public static let security: [SecurityCheck: SecurityState] = [
        .firewall: .good("On"), .fileVault: .good("On"), .gatekeeper: .good("On"), .sip: .good("On"),
        .airDrop: .weak("Everyone"),
    ]

    public static func privacyLog(now: Date) -> PrivacyLog {
        PrivacyLog(events: [
            PrivacyEvent(date: now.addingTimeInterval(-3 * 3_600), device: .mic, on: true, apps: ["FaceTime"]),
            PrivacyEvent(date: now.addingTimeInterval(-3 * 3_600 + 25 * 60), device: .mic, on: false),
            PrivacyEvent(date: now.addingTimeInterval(-40 * 60), device: .camera, on: true),
            PrivacyEvent(date: now.addingTimeInterval(-2 * 60), device: .mic, on: true, apps: ["FaceTime"]),
        ])
    }

    public static func batteryHistory(now: Date, calendar: Calendar = .current) -> BatteryHistory {
        let readings = (0..<8).reversed().compactMap { week -> BatteryReading? in
            guard let day = calendar.date(byAdding: .day, value: -7 * week, to: now) else { return nil }
            return BatteryReading(day: BatteryHistory.dayString(day, calendar: calendar), healthPercent: 94 + week / 3,
                                  cycles: 214 - week * 6)
        }
        return BatteryHistory(readings: readings)
    }

    public static func awaySummary(now: Date) -> AwayLog.Summary {
        AwayLog.Summary(start: now.addingTimeInterval(-2 * 3_600 - 10 * 60), end: now, events: [
            .init(date: now.addingTimeInterval(-95 * 60), icon: "hourglass", text: "“Fix the checkout redirect” went quiet"),
            .init(date: now.addingTimeInterval(-40 * 60), icon: "checkmark.circle.fill", text: "Codex finished"),
        ], batteryStart: 96, batteryEnd: 82)
    }

    public static func auditLog(now: Date) -> AuditLog {
        var log = AuditLog()
        log.append("Keep awake", "until 5:00 PM", at: now.addingTimeInterval(-3 * 3_600))
        log.append("Lid session started", "sleep after 3 h closed", at: now.addingTimeInterval(-2 * 3_600))
        log.append("Microphone muted", "lid closed", at: now.addingTimeInterval(-2 * 3_600 + 60))
        log.append("Lid session end requested", "all agents finished", at: now.addingTimeInterval(-30 * 60))
        log.append("Quit app", "Music", at: now.addingTimeInterval(-5 * 60))
        return log
    }
}
