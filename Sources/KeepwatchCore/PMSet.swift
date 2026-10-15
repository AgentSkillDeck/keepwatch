import Foundation

/// Parsing for `pmset` output and building of the few commands Keepwatch runs.
/// Parsing is pure so it can be unit-tested against captured output.
public enum PMSet {
    /// Settings read from `pmset -g`.
    public struct Settings: Equatable, Sendable {
        /// `SleepDisabled 1`: set by `pmset -a disablesleep 1`; keeps the Mac
        /// awake even with the lid closed. Absent from the output when off.
        public var sleepDisabled: Bool
        public var lowPowerMode: Bool?
        /// Raw `sleep` minutes (0 = never).
        public var sleepMinutes: Int?
        public var displaySleepMinutes: Int?
        /// Process names pmset reports as preventing sleep, e.g. "Amphetamine".
        public var sleepPreventedBy: [String]
    }

    public static func parseSettings(_ output: String) -> Settings {
        var settings = Settings(sleepDisabled: false, lowPowerMode: nil, sleepMinutes: nil,
                                displaySleepMinutes: nil, sleepPreventedBy: [])
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Keys can contain spaces ("Sleep On Power Button"), so split on the
            // first run of 2+ spaces or a tab, falling back to the last token.
            guard let (key, value) = splitKeyValue(line) else { continue }
            let firstValueToken = value.split(separator: " ").first.map(String.init) ?? value
            switch key.lowercased() {
            case "sleepdisabled":
                settings.sleepDisabled = firstValueToken == "1"
            case "lowpowermode":
                settings.lowPowerMode = firstValueToken == "1"
            case "sleep":
                settings.sleepMinutes = Int(firstValueToken)
                settings.sleepPreventedBy = parsePreventers(value)
            case "displaysleep":
                settings.displaySleepMinutes = Int(firstValueToken)
            default:
                break
            }
        }
        return settings
    }

    /// "1 (sleep prevented by caffeinate, powerd, Amphetamine, caffeinate)"
    /// becomes ["caffeinate", "powerd", "Amphetamine"], de-duplicated in order.
    static func parsePreventers(_ value: String) -> [String] {
        guard let open = value.range(of: "prevented by "),
              let close = value.range(of: ")", range: open.upperBound..<value.endIndex)
        else { return [] }
        var seen = Set<String>()
        return value[open.upperBound..<close.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func splitKeyValue(_ line: String) -> (String, String)? {
        if line.isEmpty || line.hasSuffix(":") { return nil }
        if let tab = line.firstIndex(of: "\t") {
            let k = line[..<tab].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            return k.isEmpty ? nil : (k, v)
        }
        if let gap = line.range(of: "  ") {
            let k = line[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
            let v = line[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            return k.isEmpty ? nil : (k, v)
        }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// One assertion row from `pmset -g assertions` ("Listed by owning process").
    public struct OwnedAssertion: Equatable, Sendable {
        public var pid: Int32
        public var process: String
        public var type: String
        public var name: String
    }

    public static func parseAssertions(_ output: String) -> [OwnedAssertion] {
        // e.g.  pid 10730(Amphetamine): [0x0000...] 93:13:07 PreventUserIdleSystemSleep named: "Amphetamine (Single-Use - System)"
        let pattern = #"pid (\d+)\(([^)]*)\): \[[^\]]*\] \S+ (\S+) named: "(.*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var rows: [OwnedAssertion] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range), m.numberOfRanges == 5,
                  let pidR = Range(m.range(at: 1), in: line),
                  let procR = Range(m.range(at: 2), in: line),
                  let typeR = Range(m.range(at: 3), in: line),
                  let nameR = Range(m.range(at: 4), in: line),
                  let pid = Int32(line[pidR])
            else { continue }
            rows.append(OwnedAssertion(pid: pid, process: String(line[procR]),
                                       type: String(line[typeR]), name: String(line[nameR])))
        }
        return rows
    }

    /// The shell command for lid-closed mode. Needs root; Keepwatch runs it only
    /// through an explicit admin prompt (see `LidMode`).
    public static func disableSleepCommand(_ disabled: Bool) -> String {
        "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
    }

    /// AppleScript that asks the user for admin rights and runs `command`.
    /// The command is a fixed literal from this file, never user input.
    public static func adminAppleScript(for command: String, prompt: String) -> String {
        appleScript(for: command, prompt: prompt, admin: true)
    }

    /// `admin: false` exists so tests can run the exact same escaping through
    /// osascript as the current user.
    static func appleScript(for command: String, prompt: String, admin: Bool) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        guard admin else { return "do shell script \"\(esc(command))\"" }
        return "do shell script \"\(esc(command))\" with prompt \"\(esc(prompt))\" with administrator privileges"
    }
}
