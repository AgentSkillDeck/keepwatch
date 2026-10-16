import Foundation

/// The one-click keep-awake lengths. The menu shows the few the user picks;
/// the rest stay one click away in its "More" menu.
public enum AwakePreset: String, CaseIterable, Identifiable, Sendable {
    case m30, h1, h2, h3, h4, h8, h12, d1, forever

    public var id: String { rawValue }

    /// nil means "until turned off".
    public var seconds: TimeInterval? {
        switch self {
        case .m30: 1_800
        case .h1: 3_600
        case .h2: 7_200
        case .h3: 10_800
        case .h4: 14_400
        case .h8: 28_800
        case .h12: 43_200
        case .d1: 86_400
        case .forever: nil
        }
    }

    public var label: String {
        switch self {
        case .m30: "30 min"
        case .h1: "1 h"
        case .h2: "2 h"
        case .h3: "3 h"
        case .h4: "4 h"
        case .h8: "8 h"
        case .h12: "12 h"
        case .d1: "1 day"
        case .forever: "∞"
        }
    }

    /// What the menu shows before the user chooses.
    public static let menuDefaults: [AwakePreset] = [.h1, .h3, .h8, .forever]
    /// The menu row has room for this many.
    public static let menuMax = 4

    /// The user's saved choice, cleaned up: known names only, no repeats, in
    /// the canonical order, at most `menuMax`, and never empty.
    public static func menuSelection(from saved: [String]?) -> [AwakePreset] {
        guard let saved else { return menuDefaults }
        let chosen = Set(saved.compactMap(AwakePreset.init(rawValue:)))
        let ordered = allCases.filter(chosen.contains).prefix(menuMax)
        return ordered.isEmpty ? menuDefaults : Array(ordered)
    }

    /// Adds or removes `preset`, keeping the selection valid. Adding when full
    /// is refused rather than silently dropping another choice.
    public static func toggle(_ preset: AwakePreset, in selection: [AwakePreset]) -> [AwakePreset] {
        if selection.contains(preset) {
            let rest = selection.filter { $0 != preset }
            return rest.isEmpty ? selection : rest
        }
        guard selection.count < menuMax else { return selection }
        let chosen = Set(selection + [preset])
        return allCases.filter(chosen.contains)
    }
}
