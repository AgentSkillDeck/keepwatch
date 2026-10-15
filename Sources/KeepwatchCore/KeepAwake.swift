import Foundation

/// What the user asked Keepwatch to do about sleep.
public enum KeepAwakeMode: Equatable, Codable, Sendable {
    case off
    case indefinite
    /// Until a fixed time.
    case until(Date)
    /// While at least one agent CLI is running. `grace` keeps the Mac awake a
    /// little after the last agent exits, so a quick restart doesn't let it sleep.
    case whileAgentsRun(grace: TimeInterval)
}

/// Pure decision logic for keep-awake: given the mode, the clock and the
/// running agents, should an assertion be held, and did a session just end?
public struct KeepAwakeEngine: Sendable {
    public private(set) var mode: KeepAwakeMode = .off
    /// Last time an agent was seen running, for the grace period.
    public private(set) var lastAgentSeen: Date?
    /// Agents seen on the previous tick, to detect "agent finished".
    public private(set) var previousAgents: Set<String> = []

    public init() {}

    public enum Event: Equatable, Sendable {
        /// An agent that was running is no longer running.
        case agentFinished(String)
        /// A timed session ran out and switched itself off.
        case timerEnded
        /// The whileAgentsRun grace expired with no agents.
        case agentsIdle
    }

    public struct Decision: Equatable, Sendable {
        public var holdAssertion: Bool
        public var events: [Event]
        /// Seconds left for a timed session, if any.
        public var remaining: TimeInterval?
    }

    public mutating func set(_ newMode: KeepAwakeMode, now: Date = Date()) {
        mode = newMode
        lastAgentSeen = nil
        if case .whileAgentsRun = newMode { lastAgentSeen = nil }
    }

    /// Advance one tick. `agents` is the set of agent display names running now.
    public mutating func tick(now: Date, agents: Set<String>) -> Decision {
        var events: [Event] = []
        for finished in previousAgents.subtracting(agents).sorted() {
            events.append(.agentFinished(finished))
        }
        previousAgents = agents
        if !agents.isEmpty { lastAgentSeen = now }

        switch mode {
        case .off:
            return Decision(holdAssertion: false, events: events, remaining: nil)
        case .indefinite:
            return Decision(holdAssertion: true, events: events, remaining: nil)
        case .until(let end):
            let remaining = end.timeIntervalSince(now)
            if remaining <= 0 {
                mode = .off
                events.append(.timerEnded)
                return Decision(holdAssertion: false, events: events, remaining: 0)
            }
            return Decision(holdAssertion: true, events: events, remaining: remaining)
        case .whileAgentsRun(let grace):
            if !agents.isEmpty { return Decision(holdAssertion: true, events: events, remaining: nil) }
            if let seen = lastAgentSeen, now.timeIntervalSince(seen) < max(0, grace) {
                return Decision(holdAssertion: true, events: events, remaining: nil)
            }
            // Stay armed: the next agent that starts takes the hold again.
            if lastAgentSeen != nil {
                lastAgentSeen = nil
                events.append(.agentsIdle)
            }
            return Decision(holdAssertion: false, events: events, remaining: nil)
        }
    }
}
