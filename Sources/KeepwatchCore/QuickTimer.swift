import Foundation

/// A "back in N minutes" countdown. While it runs the Mac can be kept awake,
/// the menu bar shows the time left, and a notification says when it ends.
public struct QuickTimer: Equatable, Codable, Sendable {
    public var end: Date
    public var minutes: Int
    /// Keepwatch turned keep-awake on for this timer, so it may turn it off.
    public var keptAwake: Bool

    public static let choices = [5, 10, 15, 25, 45, 60]
    public static let maxMinutes = 24 * 60

    public init?(minutes: Int, now: Date, keepAwake: Bool) {
        guard minutes > 0, minutes <= Self.maxMinutes else { return nil }
        self.end = now.addingTimeInterval(TimeInterval(minutes) * 60)
        self.minutes = minutes
        self.keptAwake = keepAwake
    }

    public func remaining(at now: Date) -> TimeInterval { max(0, end.timeIntervalSince(now)) }
    public func isDone(at now: Date) -> Bool { now >= end }

    /// Short text for the menu bar: "12m", "1m" in the last minute, "1h05".
    public func menuBarText(at now: Date) -> String { Self.menuBarText(left: remaining(at: now)) }

    public static func menuBarText(left: TimeInterval) -> String {
        guard left.isFinite, left > 0 else { return "0m" }
        // Whole minutes only: redrawing the menu bar every second costs CPU.
        let minutes = Int((left / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : String(format: "%02d", minutes % 60))" : "\(minutes)m"
    }
}
