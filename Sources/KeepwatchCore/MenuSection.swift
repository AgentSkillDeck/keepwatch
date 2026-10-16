import Foundation

/// The parts of the menu-bar window. The user picks which ones show; the
/// order is fixed so the menu always reads the same way.
public enum MenuSection: String, CaseIterable, Identifiable, Sendable {
    case privacy, keepAwake, timer, laptopClosed, agents, memory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .privacy: "Privacy (mic and camera)"
        case .keepAwake: "Keep awake"
        case .timer: "Quick timer"
        case .laptopClosed: "Laptop closed"
        case .agents: "Agent sessions"
        case .memory: "Apps using the most memory"
        }
    }

    public var icon: String {
        switch self {
        case .privacy: "hand.raised.fill"
        case .keepAwake: "eye.fill"
        case .timer: "timer"
        case .laptopClosed: "laptopcomputer.slash"
        case .agents: "terminal.fill"
        case .memory: "memorychip"
        }
    }

    public static let defaults: [MenuSection] = [.privacy, .keepAwake, .timer, .laptopClosed]

    /// The saved choice: known names only, no repeats, canonical order. An
    /// empty saved list is kept (a status-only menu is a valid choice).
    public static func selection(from saved: [String]?) -> [MenuSection] {
        guard let saved else { return defaults }
        let chosen = Set(saved.compactMap(MenuSection.init(rawValue:)))
        return allCases.filter(chosen.contains)
    }

    public static func toggle(_ section: MenuSection, in selection: [MenuSection]) -> [MenuSection] {
        var chosen = Set(selection)
        if chosen.contains(section) { chosen.remove(section) } else { chosen.insert(section) }
        return allCases.filter(chosen.contains)
    }
}
