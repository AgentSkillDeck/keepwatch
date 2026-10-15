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

    /// Longest keep-awake a URL may request (24 h).
    public static let maxMinutes = 24 * 60

    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "keepwatch" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch (host, path) {
        case ("awake", ""):
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
        default: return nil
        }
    }
}
