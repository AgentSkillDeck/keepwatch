import Foundation

/// Mac security settings Keepwatch can read as a normal user, without a
/// password or a permission prompt. Each check shows its state and opens the
/// System Settings pane that changes it; Keepwatch never changes them itself.
public enum SecurityCheck: String, CaseIterable, Identifiable, Sendable {
    case firewall, fileVault, gatekeeper, sip, airDrop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .firewall: "Firewall"
        case .fileVault: "FileVault disk encryption"
        case .gatekeeper: "Gatekeeper"
        case .sip: "System Integrity Protection"
        case .airDrop: "AirDrop"
        }
    }

    public var icon: String {
        switch self {
        case .firewall: "flame"
        case .fileVault: "lock.shield"
        case .gatekeeper: "checkmark.shield"
        case .sip: "cpu"
        case .airDrop: "dot.radiowaves.left.and.right"
        }
    }

    /// The System Settings pane that changes this setting, if there is one.
    public var settingsURL: URL? {
        switch self {
        case .firewall: URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
        case .fileVault: URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")
        case .gatekeeper: URL(string: "x-apple.systempreferences:com.apple.preference.security?Security")
        case .sip: nil // changed only from Recovery
        case .airDrop: URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")
        }
    }

    /// The tool and arguments that report this setting.
    var probe: (String, [String]) {
        switch self {
        case .firewall: ("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        case .fileVault: ("/usr/bin/fdesetup", ["status"])
        case .gatekeeper: ("/usr/sbin/spctl", ["--status"])
        case .sip: ("/usr/bin/csrutil", ["status"])
        case .airDrop: ("/usr/bin/defaults", ["read", "com.apple.sharingd", "DiscoverableMode"])
        }
    }

    public func read() -> SecurityState {
        let (tool, args) = probe
        return parse(SystemState.run(tool, args))
    }

    /// Turns the tool's output into a state. Unknown output is `.unknown`, never a guess.
    public func parse(_ output: String?) -> SecurityState {
        let text = (output ?? "").lowercased()
        switch self {
        case .firewall:
            if text.contains("state = 0") || text.contains("is disabled") { return .weak("Off") }
            if text.contains("state = 1") || text.contains("state = 2") || text.contains("is enabled") { return .good("On") }
        case .fileVault:
            if text.contains("filevault is on") { return .good("On") }
            if text.contains("encryption in progress") { return .good("Encrypting") }
            if text.contains("filevault is off") { return .weak("Off") }
        case .gatekeeper:
            if text.contains("assessments enabled") { return .good("On") }
            if text.contains("assessments disabled") { return .weak("Off") }
        case .sip:
            if text.contains("status: enabled") { return .good("On") }
            if text.contains("status: disabled") { return .weak("Off") }
            if text.contains("custom configuration") { return .weak("Custom") }
        case .airDrop:
            // No key means the macOS default, Contacts Only.
            guard output != nil else { return .good("Contacts only") }
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if v == "off" { return .good("Off") }
            if v == "contacts only" { return .good("Contacts only") }
            if v == "everyone" { return .weak("Everyone") }
        }
        return .unknown
    }
}

public enum SecurityState: Equatable, Sendable {
    /// The safe setting is on.
    case good(String)
    /// Less safe than the default; worth a look.
    case weak(String)
    case unknown

    public var label: String {
        switch self {
        case .good(let s), .weak(let s): s
        case .unknown: "Unknown"
        }
    }
}
