import Foundation

/// The `keepwatch` command line, parsed. Parsing is pure and tested; the
/// KeepwatchCLI target executes it.
///
/// Agents can keep the Mac awake, read status and end a lid session. They can
/// not start a lid session: that needs an administrator password, and only a
/// person at the Mac may give it.
public enum CLICommand: Equatable, Sendable {
    case status(json: Bool)
    /// Keep awake for N minutes / indefinitely / while agents run, or stop.
    case awake(AwakeRequest)
    /// Keep awake while a child command runs; exit with its status.
    case run(command: [String], display: Bool)
    case mic(mute: Bool)
    case lidEnd
    case ports(json: Bool)
    case help
    case version

    public enum AwakeRequest: Equatable, Sendable {
        case minutes(Int)
        case indefinitely
        case whileAgentsRun
        case off
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownCommand(String)
        case bad(String)

        public var description: String {
            switch self {
            case .unknownCommand(let c): "unknown command '\(c)'. Run 'keepwatch help'."
            case .bad(let m): m
            }
        }
    }

    public static let usage = """
    keepwatch: keep your Mac awake for AI agents, and check mic, camera and power.

    USAGE
      keepwatch status [--json]          power, sleep blockers, agents, mic/camera, lid session
      keepwatch awake [--minutes N]      keep awake N minutes (max 1440), or until 'awake --off'
      keepwatch awake --agents           keep awake while agent CLIs (Claude Code, Codex…) run
      keepwatch awake --off              stop keeping awake
      keepwatch run [--display] -- CMD…  keep awake while CMD runs; exits with CMD's status
      keepwatch mic mute|unmute          soft-mute the default microphone
      keepwatch lid end                  end a lid-closed session (turns sleep back on)
      keepwatch ports [--json]           your processes listening on TCP ports
      keepwatch version

    'awake' drives the Keepwatch app when it is running. Without the app it holds
    the Mac awake itself and keeps running until the time is up or you press Ctrl-C.
    Lid-closed sessions can only be started from the app (they need your password).

    EXIT CODES  0 ok · 1 usage error · 2 system error · otherwise CMD's status for 'run'
    """

    public static func parse(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else { return .help }
        let rest = Array(args.dropFirst())
        func json() throws -> Bool {
            for a in rest where a != "--json" { throw ParseError.bad("unexpected argument '\(a)'") }
            return rest.contains("--json")
        }
        switch first {
        case "help", "-h", "--help": return .help
        case "version", "--version": return .version
        case "status": return .status(json: try json())
        case "ports": return .ports(json: try json())
        case "awake":
            switch rest {
            case []: return .awake(.indefinitely)
            case ["--agents"]: return .awake(.whileAgentsRun)
            case ["--off"]: return .awake(.off)
            case _ where rest.count == 2 && rest[0] == "--minutes":
                guard let m = Int(rest[1]), m > 0 else { throw ParseError.bad("--minutes needs a positive whole number") }
                return .awake(.minutes(min(m, URLCommand.maxMinutes)))
            default: throw ParseError.bad("usage: keepwatch awake [--minutes N | --agents | --off]")
            }
        case "run":
            var display = false
            var i = 0
            while i < rest.count, rest[i] != "--" {
                guard rest[i] == "--display" else { throw ParseError.bad("usage: keepwatch run [--display] -- CMD [ARGS…]") }
                display = true
                i += 1
            }
            let command = Array(rest.dropFirst(i + 1))
            guard i < rest.count, !command.isEmpty else { throw ParseError.bad("usage: keepwatch run [--display] -- CMD [ARGS…]") }
            return .run(command: command, display: display)
        case "mic":
            switch rest {
            case ["mute"]: return .mic(mute: true)
            case ["unmute"]: return .mic(mute: false)
            default: throw ParseError.bad("usage: keepwatch mic mute|unmute")
            }
        case "lid":
            if rest == ["end"] { return .lidEnd }
            if rest.first == "start" {
                throw ParseError.bad("lid sessions can only be started from the Keepwatch app, because they need your administrator password")
            }
            throw ParseError.bad("usage: keepwatch lid end")
        default:
            throw ParseError.unknownCommand(first)
        }
    }

    /// The `keepwatch://` URL that asks the running app to do the same thing.
    public var appURL: URL? {
        switch self {
        case .awake(.minutes(let m)): URL(string: "keepwatch://awake?minutes=\(m)")
        case .awake(.indefinitely): URL(string: "keepwatch://awake")
        case .awake(.whileAgentsRun): URL(string: "keepwatch://awake/agents")
        case .awake(.off): URL(string: "keepwatch://awake/off")
        case .lidEnd: URL(string: "keepwatch://lid/end")
        default: nil
        }
    }
}

/// Machine-readable status for `keepwatch status --json`. Field names are a
/// public contract for agents: add fields, never rename or remove them.
public struct StatusReport: Codable, Equatable, Sendable {
    public struct Power: Codable, Equatable, Sendable {
        public var batteryPercent: Int?
        public var onBattery: Bool
        public var charging: Bool
        public var minutesRemaining: Int?
        public var healthPercent: Int?
        public var cycleCount: Int?
        public var lowPowerMode: Bool
        public var thermal: String
        public var lidClosed: Bool?

        public init(batteryPercent: Int?, onBattery: Bool, charging: Bool, minutesRemaining: Int?, healthPercent: Int?,
                    cycleCount: Int?, lowPowerMode: Bool, thermal: String, lidClosed: Bool?) {
            self.batteryPercent = batteryPercent; self.onBattery = onBattery; self.charging = charging
            self.minutesRemaining = minutesRemaining; self.healthPercent = healthPercent; self.cycleCount = cycleCount
            self.lowPowerMode = lowPowerMode; self.thermal = thermal; self.lidClosed = lidClosed
        }
    }

    public struct Sleep: Codable, Equatable, Sendable {
        /// pmset SleepDisabled: the Mac won't sleep even with the lid closed.
        public var sleepDisabled: Bool
        /// Processes pmset says are preventing idle sleep (powerd excluded).
        public var preventedBy: [String]
        /// Keepwatch (app or CLI) currently holds a keep-awake assertion.
        public var keepwatchHolding: Bool

        public init(sleepDisabled: Bool, preventedBy: [String], keepwatchHolding: Bool) {
            self.sleepDisabled = sleepDisabled; self.preventedBy = preventedBy; self.keepwatchHolding = keepwatchHolding
        }
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public var micInUse: Bool
        public var cameraInUse: Bool
        public var micMuted: Bool?
        public var micUsers: [String]

        public init(micInUse: Bool, cameraInUse: Bool, micMuted: Bool?, micUsers: [String]) {
            self.micInUse = micInUse; self.cameraInUse = cameraInUse; self.micMuted = micMuted; self.micUsers = micUsers
        }
    }

    public var version: String
    public var appRunning: Bool
    public var power: Power
    public var sleep: Sleep
    public var agents: [String]
    public var privacy: Privacy

    public init(version: String, appRunning: Bool, power: Power, sleep: Sleep, agents: [String], privacy: Privacy) {
        self.version = version; self.appRunning = appRunning; self.power = power
        self.sleep = sleep; self.agents = agents; self.privacy = privacy
    }

    public static func thermalName(_ t: LidModePolicy.Thermal) -> String {
        switch t {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
    }

    public func text() -> String {
        var lines: [String] = []
        let battery = power.batteryPercent.map { "\($0)%" } ?? "n/a"
        let source = power.onBattery ? "battery" : "power adapter"
        lines.append("Power     \(battery) on \(source)\(power.charging ? ", charging" : "")"
                     + (power.minutesRemaining.map { ", \($0 / 60) h \($0 % 60) min left" } ?? ""))
        if let h = power.healthPercent { lines.append("Battery   \(h)% health, \(power.cycleCount.map(String.init) ?? "?") cycles") }
        lines.append("Thermal   \(power.thermal)\(power.lowPowerMode ? ", Low Power Mode on" : "")")
        lines.append("Lid       \(power.lidClosed.map { $0 ? "closed" : "open" } ?? "n/a")")
        var sleepLine = sleep.sleepDisabled ? "DISABLED system-wide (stays awake with the lid closed)" : "normal"
        if !sleep.preventedBy.isEmpty { sleepLine += "; kept awake by \(sleep.preventedBy.joined(separator: ", "))" }
        lines.append("Sleep     \(sleepLine)")
        lines.append("Agents    \(agents.isEmpty ? "none running" : agents.joined(separator: ", "))")
        var privacyLine = "mic \(privacy.micInUse ? "IN USE" : "off"), camera \(privacy.cameraInUse ? "IN USE" : "off")"
        if privacy.micMuted == true { privacyLine += ", mic muted" }
        if !privacy.micUsers.isEmpty { privacyLine += " (mic: \(privacy.micUsers.joined(separator: ", ")))" }
        lines.append("Privacy   \(privacyLine)")
        lines.append("App       \(appRunning ? "running" : "not running")")
        return lines.joined(separator: "\n")
    }
}

/// Installs the `keepwatch` command by symlinking the bundled CLI into the
/// first writable directory on a standard PATH. No admin rights needed.
public enum CLIInstaller {
    public static let candidates = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]

    public enum Result: Equatable { case installed(String), alreadyInstalled(String), noWritableDirectory, failed(String) }

    public static func install(cliPath: String, fileManager fm: FileManager = .default,
                               directories: [String] = candidates) -> Result {
        for dir in directories {
            let link = dir + "/keepwatch"
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link) {
                if dest == cliPath { return .alreadyInstalled(link) }
                // Our own stale link (the app moved): replace it. Anything else: leave alone.
                guard dest.hasSuffix("/Contents/MacOS/keepwatch-cli") else { continue }
                try? fm.removeItem(atPath: link)
            } else if fm.fileExists(atPath: link) {
                continue // a real file someone else owns
            }
            if dir.hasPrefix(NSHomeDirectory()) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            guard fm.isWritableFile(atPath: dir) else { continue }
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: cliPath)
                return .installed(link)
            } catch { return .failed(error.localizedDescription) }
        }
        return .noWritableDirectory
    }
}
