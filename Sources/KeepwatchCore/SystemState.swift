import Foundation
import IOKit
import IOKit.ps

/// Power, battery and lid facts that Keepwatch shows and its safety rules use.
public struct PowerState: Equatable, Sendable {
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var charging: Bool
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Current full-charge capacity as a percentage of design capacity.
    public var healthPercent: Int?
    public var lidClosed: Bool?
    public var thermal: LidModePolicy.Thermal
    public var lowPowerMode: Bool
}

public enum SystemState {
    public static func power() -> PowerState {
        var state = PowerState(batteryPercent: nil, onBattery: false, charging: false, minutesRemaining: nil,
                               cycleCount: nil, healthPercent: nil, lidClosed: lidClosed(),
                               thermal: .init(ProcessInfo.processInfo.thermalState),
                               lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    state.batteryPercent = Swift.max(0, Swift.min(100, cur * 100 / max))
                }
                state.onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
                state.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
                if let mins = d[kIOPSTimeToEmptyKey] as? Int, mins >= 0, state.onBattery { state.minutesRemaining = mins }
            }
        }
        let battery = smartBattery()
        state.cycleCount = battery.cycles
        state.healthPercent = battery.health
        return state
    }

    /// Lid state from IOPMrootDomain's AppleClamshellState; nil on desktops.
    public static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    /// Cycle count and health from AppleSmartBattery. Key names are not
    /// documented, so every read is optional.
    static func smartBattery() -> (cycles: Int?, health: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        let cycles = int("CycleCount")
        // On Apple Silicon "MaxCapacity" is a percentage; the raw mAh value is
        // AppleRawMaxCapacity. Use raw/design when both exist.
        var health: Int?
        if let raw = int("AppleRawMaxCapacity"), let design = int("DesignCapacity"), design > 0, raw > 0 {
            health = min(100, raw * 100 / design)
        }
        return (cycles, health)
    }

    /// Run a fixed command and return stdout; used for `pmset -g` reads only.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data.prefix(1 << 20), encoding: .utf8)
    }

    public static func pmsetSettings() -> PMSet.Settings? {
        run("/usr/bin/pmset", ["-g"]).map(PMSet.parseSettings)
    }
}

/// Deep links into System Settings privacy panes.
public enum PrivacyPane: String, CaseIterable, Sendable {
    case camera = "Privacy_Camera"
    case microphone = "Privacy_Microphone"
    case screenRecording = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"
    case fullDiskAccess = "Privacy_AllFiles"
    case automation = "Privacy_Automation"
    case location = "Privacy_LocationServices"
    case loginItems = "LoginItems"

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "Full Disk Access"
        case .automation: "Automation"
        case .location: "Location Services"
        case .loginItems: "Login Items & Extensions"
        }
    }

    public var url: URL? {
        switch self {
        case .loginItems: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        default: URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
        }
    }
}
