import Foundation

/// User-level system toggles backed by `defaults`. Every toggle reads the real
/// value first, writes one key, and restarts only the app that owns it, so each
/// change is visible and reversible with the same switch.
public enum QuickToggle: String, CaseIterable, Identifiable, Sendable {
    case dockAutohide
    case showHiddenFiles
    case showFileExtensions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dockAutohide: "Hide the Dock automatically"
        case .showHiddenFiles: "Show hidden files in Finder"
        case .showFileExtensions: "Show all file extensions"
        }
    }

    public var domain: String {
        switch self {
        case .dockAutohide: "com.apple.dock"
        case .showHiddenFiles: "com.apple.finder"
        case .showFileExtensions: "NSGlobalDomain"
        }
    }

    public var key: String {
        switch self {
        case .dockAutohide: "autohide"
        case .showHiddenFiles: "AppleShowAllFiles"
        case .showFileExtensions: "AppleShowAllExtensions"
        }
    }

    /// The process to restart so the change takes effect, if any.
    public var restarts: String? {
        switch self {
        case .dockAutohide: "Dock"
        case .showHiddenFiles, .showFileExtensions: "Finder"
        }
    }

    /// Arguments for `/usr/bin/defaults` to write `value`.
    public func writeArguments(_ value: Bool) -> [String] {
        ["write", domain, key, "-bool", value ? "true" : "false"]
    }

    public func readArguments() -> [String] { ["read", domain, key] }

    /// `defaults read` prints 1/0 or true/false; anything else (missing key) is off.
    public static func parse(_ output: String?) -> Bool {
        guard let v = output?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes"
    }

    public func read() -> Bool {
        Self.parse(SystemState.run("/usr/bin/defaults", readArguments()))
    }

    public func write(_ value: Bool) {
        _ = SystemState.run("/usr/bin/defaults", writeArguments(value))
        if let app = restarts { _ = SystemState.run("/usr/bin/killall", [app]) }
    }
}
