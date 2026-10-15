import Foundation

/// Fail-safe policy for lid-closed mode (`pmset -a disablesleep 1`).
///
/// That setting is persistent and system-wide: it outlives Keepwatch, a crash and
/// a reboot. A Mac left sleepless in a bag can overheat and drain flat, so every
/// path that could leave it on is covered by a rule here, and the rules are pure
/// so they can be tested without touching the real setting.
public struct LidModePolicy: Equatable, Codable, Sendable {
    /// Only allow lid mode on external power. On by default: a closed Mac on
    /// battery is the "forgotten in a bag" case this whole policy exists for.
    public var requireExternalPower: Bool = true
    /// Turn lid mode off at or below this battery percentage when on battery.
    public var minBatteryPercent: Int = 15
    /// Turn lid mode off when the thermal state reaches this level.
    public var maxThermal: Thermal = .serious
    /// Lid mode never runs longer than this without being renewed.
    public var maxDuration: TimeInterval = 8 * 3600

    public init() {}

    public enum Thermal: Int, Codable, Comparable, Sendable {
        case nominal = 0, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .critical // unknown: be safe
            }
        }
    }
}

/// What Keepwatch believes about lid mode, persisted before any change is made.
public struct LidModeIntent: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var since: Date?
    public var expires: Date?

    public init(enabled: Bool, since: Date? = nil, expires: Date? = nil) {
        self.enabled = enabled
        self.since = since
        self.expires = expires
    }

    public static let off = LidModeIntent(enabled: false)
}

public enum LidModeAction: Equatable, Sendable {
    case none
    /// Turn sleep back on now, for the given reason.
    case restore(Reason)
    /// The system has sleep disabled but Keepwatch didn't do it (another tool,
    /// or a leftover from a crash before intent was saved). Ask the user.
    case askAboutForeignSetting

    public enum Reason: String, Equatable, Sendable {
        case expired = "lid mode time limit reached"
        case lowBattery = "battery is low"
        case onBattery = "power adapter was unplugged"
        case thermal = "Mac is running hot"
        case quitting = "Keepwatch is quitting"
        case staleAfterLaunch = "left on from a previous run"
    }
}

public enum LidModeGuard {
    /// Decide what to do when Keepwatch starts.
    /// - Parameters:
    ///   - systemSleepDisabled: the real state from `pmset -g`.
    ///   - intent: what Keepwatch saved last time.
    ///   - watchdogAlive: whether the root watchdog from that session still runs.
    ///     After a reboot it is gone but `SleepDisabled` persists.
    ///   - bootTime: when the Mac last booted. A boot after the session began
    ///     means the watchdog is gone whatever the process list says.
    public static func onLaunch(systemSleepDisabled: Bool, intent: LidModeIntent, watchdogAlive: Bool,
                                bootTime: Date? = nil) -> LidModeAction {
        guard systemSleepDisabled else { return .none }
        guard intent.enabled else { return .askAboutForeignSetting }
        let rebootedSince = { () -> Bool in
            guard let boot = bootTime, let since = intent.since else { return false }
            return boot > since
        }()
        // Our session is still supervised: leave it to the watchdog.
        if watchdogAlive && !rebootedSince { return .none }
        // Ours, but unsupervised (reboot or killed watchdog): restore.
        return .restore(.staleAfterLaunch)
    }

    /// Decide on every tick while lid mode is on.
    public static func onTick(intent: LidModeIntent, policy: LidModePolicy, now: Date,
                              batteryPercent: Int?, onBattery: Bool,
                              thermal: LidModePolicy.Thermal) -> LidModeAction {
        guard intent.enabled else { return .none }
        if let expires = intent.expires, now >= expires { return .restore(.expired) }
        if let since = intent.since, now.timeIntervalSince(since) >= policy.maxDuration { return .restore(.expired) }
        if thermal >= policy.maxThermal { return .restore(.thermal) }
        if onBattery, policy.requireExternalPower { return .restore(.onBattery) }
        if onBattery, let pct = batteryPercent, pct <= policy.minBatteryPercent { return .restore(.lowBattery) }
        return .none
    }

    /// The expiry for a new lid-mode session, capped by policy.
    public static func expiry(requested: TimeInterval?, policy: LidModePolicy, now: Date) -> Date {
        let duration = min(max(60, requested ?? policy.maxDuration), policy.maxDuration)
        return now.addingTimeInterval(duration)
    }
}

public enum BootTime {
    /// `kern.boottime`, or nil if it can't be read.
    public static func current() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
