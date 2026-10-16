import Foundation

/// Commands accepted from `keepwatch://` URLs (Shortcuts, Raycast, scripts).
///
/// Any web page can open a custom URL (the browser asks first), so only
/// harmless, reversible actions are exposed. Starting a lid session is NOT
/// reachable by URL: it would put a password prompt in front of the user on a
/// page's say-so. Ending one is allowed, because it only restores sleep.
public enum URLCommand: Equatable, Sendable {
    case awake(minutes: Int)
    case awakeIndefinitely
    case awakeWhileAgentsRun
    case awakeOff
    case micMute(Bool)
    case endLidSession
    case dashboard
    case timer(minutes: Int)
    case timerCancel

    /// Longest timed keep-awake a URL or the CLI may request (30 days).
    public static let maxMinutes = Int(AwakeDuration.maxSeconds / 60)

    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "keepwatch" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch (host, path) {
        case ("awake", ""):
            if let raw = query.first(where: { $0.name == "for" })?.value {
                guard let seconds = AwakeDuration.parse(raw) else { return nil }
                return .awake(minutes: AwakeDuration.minutes(seconds))
            }
            if let raw = query.first(where: { $0.name == "minutes" })?.value {
                guard let m = Int(raw), m > 0 else { return nil }
                return .awake(minutes: min(m, maxMinutes))
            }
            return .awakeIndefinitely
        case ("awake", "agents"): return .awakeWhileAgentsRun
        case ("awake", "off"): return .awakeOff
        case ("mic", "mute"): return .micMute(true)
        case ("mic", "unmute"): return .micMute(false)
        case ("lid", "end"): return .endLidSession
        case ("dashboard", ""): return .dashboard
        case ("timer", "cancel"): return .timerCancel
        case ("timer", ""):
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "minutes" }?.value
            guard let m = value.flatMap({ Int($0) }), m > 0, m <= QuickTimer.maxMinutes else { return nil }
            return .timer(minutes: m)
        default: return nil
        }
    }
}

/// How the CLI asks the running app to start a lid session. Local only (a
/// distributed notification); the app still shows the macOS password prompt.
public enum LidRequest {
    public static let notificationName = "app.keepwatch.Keepwatch.lid-start-request"

    /// Hours from the request, rounded to half hours and kept within 0.5…12; nil if absent or bad.
    public static func hours(from info: [AnyHashable: Any]?) -> Double? {
        guard let raw = info?["hours"] else { return nil }
        let h: Double? = (raw as? Double) ?? (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
        guard let h, h.isFinite, h > 0 else { return nil }
        return min(12, max(0.5, (h * 2).rounded() / 2))
    }
}
