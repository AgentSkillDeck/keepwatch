import Foundation

/// Custom keep-awake lengths typed by people and agents: "45m", "1h30m",
/// "1.5h", "3 days", "2w". Parsing is pure, bounded and tested.
public enum AwakeDuration {
    /// Longest timed keep-awake (30 days). Longer than that, use "until turned off".
    public static let maxSeconds: TimeInterval = 30 * 86_400
    /// Input longer than this is rejected before parsing.
    static let maxInputLength = 64

    public enum Unit: String, CaseIterable, Identifiable, Sendable {
        case minutes, hours, days, weeks
        public var id: String { rawValue }
        public var seconds: TimeInterval {
            switch self {
            case .minutes: 60
            case .hours: 3_600
            case .days: 86_400
            case .weeks: 604_800
            }
        }
        public var label: String {
            switch self {
            case .minutes: "min"
            case .hours: "hours"
            case .days: "days"
            case .weeks: "weeks"
            }
        }
    }

    static let unitWords: [String: TimeInterval] = [
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3_600, "hr": 3_600, "hrs": 3_600, "hour": 3_600, "hours": 3_600,
        "d": 86_400, "day": 86_400, "days": 86_400,
        "w": 604_800, "wk": 604_800, "wks": 604_800, "week": 604_800, "weeks": 604_800,
    ]

    /// Seconds for `text`, clamped to `maxSeconds`, or nil if it isn't a
    /// positive duration with a unit on every number.
    public static func parse(_ text: String) -> TimeInterval? {
        guard text.count <= maxInputLength else { return nil }
        let chars = Array(text.lowercased().filter { !$0.isWhitespace })
        guard !chars.isEmpty else { return nil }
        var total: TimeInterval = 0
        var i = 0
        while i < chars.count {
            var number = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "." {
                number.append(chars[i]); i += 1
            }
            var unit = ""
            while i < chars.count, chars[i].isASCII, chars[i].isLetter {
                unit.append(chars[i]); i += 1
            }
            guard let value = Double(number), value.isFinite, value >= 0,
                  let scale = unitWords[unit] else { return nil }
            total += value * scale
            guard total.isFinite else { return nil }
        }
        guard total >= 1 else { return nil }
        return min(total, maxSeconds)
    }

    /// Seconds for `amount` of `unit`, or nil if it isn't positive.
    public static func seconds(_ amount: Double, _ unit: Unit) -> TimeInterval? {
        guard amount.isFinite, amount > 0 else { return nil }
        return min(amount * unit.seconds, maxSeconds)
    }

    /// The next time the clock reads `hh:mm` ("18:30", "6:05"), today or tomorrow.
    public static func nextOccurrence(of text: String, after now: Date, calendar: Calendar = .current) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isASCII) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime)
    }

    /// Whole minutes for `seconds`, rounded up, at least 1.
    public static func minutes(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return Int((min(seconds, maxSeconds) / 60).rounded(.up)).clamped(1, Int(maxSeconds / 60))
    }

    /// "45 min", "2 h 5 min", "3 d 4 h", "2 w 1 d".
    public static func describe(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0 s" }
        let s = Int(max(0, min(seconds, maxSeconds * 2)))
        let w = s / 604_800, d = (s % 604_800) / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if w > 0 { return d > 0 ? "\(w) w \(d) d" : "\(w) w" }
        if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return m > 0 ? "\(m) min" : "\(s) s"
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
