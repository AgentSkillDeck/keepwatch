import Foundation

/// A time limit for agent sessions, so a forgotten or looping agent doesn't
/// run all night. Off by default; it can warn or stop the session.
public enum AgentBudget {
    public static let choicesHours = [1, 2, 4, 8]

    /// Sessions that have run longer than `limitHours` and weren't handled yet.
    public static func overLimit(_ sessions: [AgentSession], limitHours: Int, handled: Set<Int32>, now: Date) -> [AgentSession] {
        guard limitHours > 0 else { return [] }
        let limit = TimeInterval(min(limitHours, 24 * 7)) * 3_600
        return sessions.filter { s in
            guard !handled.contains(s.pid), let started = s.started else { return false }
            return now.timeIntervalSince(started) >= limit
        }
    }
}
