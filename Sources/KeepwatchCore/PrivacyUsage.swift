import Foundation

/// Per-app mic and camera use, worked out from the privacy history: how many
/// times and for how long. macOS doesn't say which app holds the camera, so
/// camera time is listed as "Camera (app unknown)".
public struct PrivacyUsage: Equatable, Identifiable, Sendable {
    public var app: String
    public var device: PrivacyEvent.Device
    public var sessions: Int
    public var seconds: TimeInterval
    public var id: String { "\(device.rawValue)-\(app)" }

    public static let unknownMic = "Microphone (app unknown)"
    public static let unknownCamera = "Camera (app unknown)"
}

extension PrivacyLog {
    /// Use since `since`, longest first. A session still on counts up to `now`;
    /// time before `since` is cut off.
    public func usage(since: Date, now: Date) -> [PrivacyUsage] {
        var open: [PrivacyEvent.Device: PrivacyEvent] = [:]
        var totals: [String: PrivacyUsage] = [:]

        func close(_ on: PrivacyEvent, at end: Date) {
            let start = max(on.date, since)
            let seconds = max(0, end.timeIntervalSince(start))
            guard end > since else { return }
            let unknown = on.device == .mic ? PrivacyUsage.unknownMic : PrivacyUsage.unknownCamera
            let apps = on.apps.isEmpty ? [unknown] : Array(Set(on.apps.prefix(10)))
            for app in apps {
                let key = "\(on.device.rawValue)-\(app)"
                var u = totals[key] ?? PrivacyUsage(app: app, device: on.device, sessions: 0, seconds: 0)
                u.sessions += 1
                u.seconds += seconds
                totals[key] = u
            }
        }

        for e in events.sorted(by: { $0.date < $1.date }) {
            if e.on {
                if let prev = open[e.device] { close(prev, at: e.date) } // a new "on" ends the last one
                open[e.device] = e
            } else if let prev = open.removeValue(forKey: e.device) {
                close(prev, at: e.date)
            }
        }
        for prev in open.values { close(prev, at: max(now, prev.date)) }
        return totals.values.sorted { ($0.seconds, $0.app) > ($1.seconds, $1.app) }
    }
}
