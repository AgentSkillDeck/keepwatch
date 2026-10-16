import Foundation

/// What happened while you were away from the Mac (screen off or lid shut):
/// which agents finished or started waiting, whether a lid session ended, and
/// what it cost in battery. Kept in memory only, never written to disk.
public struct AwayLog: Equatable, Sendable {
    public struct Event: Equatable, Sendable, Identifiable {
        public var date: Date
        public var icon: String
        public var text: String
        public var id: String { "\(date.timeIntervalSince1970)-\(text)" }

        public init(date: Date, icon: String, text: String) {
            self.date = date
            self.icon = icon
            self.text = text
        }
    }

    public struct Summary: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var events: [Event]
        public var batteryStart: Int?
        public var batteryEnd: Int?

        public var duration: TimeInterval { end.timeIntervalSince(start) }
        /// Percentage points used, if both readings exist and it went down.
        public var batteryUsed: Int? {
            guard let a = batteryStart, let b = batteryEnd, a > b else { return nil }
            return a - b
        }
    }

    /// Absences shorter than this, with nothing to report, aren't summarised.
    public static let minimumAway: TimeInterval = 10 * 60
    static let maxEvents = 50

    public private(set) var start: Date?
    private var batteryStart: Int?
    public private(set) var events: [Event] = []

    public init() {}

    public var isAway: Bool { start != nil }

    public mutating func leave(at date: Date, battery: Int?) {
        guard start == nil else { return }
        start = date
        batteryStart = battery
        events = []
    }

    /// Records an event, but only while away.
    public mutating func record(_ event: Event) {
        guard start != nil, events.count < Self.maxEvents else { return }
        events.append(event)
    }

    /// Ends the absence. Returns a summary if it was long or something happened.
    public mutating func comeBack(at date: Date, battery: Int?) -> Summary? {
        guard let start else { return nil }
        defer { self.start = nil; batteryStart = nil; events = [] }
        let away = date.timeIntervalSince(start)
        guard away >= 0, away >= Self.minimumAway || !events.isEmpty else { return nil }
        return Summary(start: start, end: date, events: events, batteryStart: batteryStart, batteryEnd: battery)
    }
}
