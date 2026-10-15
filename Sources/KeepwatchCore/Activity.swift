import Darwin
import Foundation

// MARK: - Agent activity

/// Whether an agent session is busy, from how much CPU it used since the last look.
public enum AgentActivity: String, Equatable, Sendable {
    case working, idle

    /// Above this share of one core, a session counts as working.
    public static let workingThreshold = 0.03

    public static func classify(cpuSeconds: TimeInterval, over interval: TimeInterval) -> AgentActivity {
        guard interval > 0, cpuSeconds.isFinite, cpuSeconds >= 0 else { return .idle }
        return cpuSeconds / interval >= workingThreshold ? .working : .idle
    }
}

/// Tracks each session's CPU time between ticks and reports when one goes
/// quiet after working, which usually means it finished or is waiting for you.
public struct AgentActivityTracker: Sendable {
    public struct State: Equatable, Sendable {
        public var activity: AgentActivity
        public var since: Date
        var lastCPU: TimeInterval
        var lastSeen: Date
        /// Worked for at least `minWork` in the current or last busy spell.
        var workedLongEnough: Bool
        var notified: Bool
    }

    /// Seconds of work before going quiet is worth a notice.
    public var minWork: TimeInterval = 60
    /// Seconds of quiet before the notice.
    public var minQuiet: TimeInterval = 45
    public private(set) var states: [Int32: State] = [:]

    public init() {}

    /// Feed the current CPU totals (seconds) per pid. Returns pids that just went quiet.
    public mutating func update(cpu: [Int32: TimeInterval], now: Date) -> [Int32] {
        var quiet: [Int32] = []
        for (pid, total) in cpu {
            guard var s = states[pid] else {
                states[pid] = State(activity: .idle, since: now, lastCPU: total, lastSeen: now,
                                    workedLongEnough: false, notified: true)
                continue
            }
            let a = AgentActivity.classify(cpuSeconds: max(0, total - s.lastCPU), over: now.timeIntervalSince(s.lastSeen))
            if a != s.activity {
                if a == .working { s.notified = false; s.workedLongEnough = false }
                s.activity = a
                s.since = now
            }
            if a == .working, now.timeIntervalSince(s.since) >= minWork { s.workedLongEnough = true }
            if a == .idle, s.workedLongEnough, !s.notified, now.timeIntervalSince(s.since) >= minQuiet {
                s.notified = true
                quiet.append(pid)
            }
            s.lastCPU = total
            s.lastSeen = now
            states[pid] = s
        }
        for pid in states.keys where cpu[pid] == nil { states[pid] = nil }
        return quiet.sorted()
    }
}

extension ProcessList {
    /// Total CPU time (user + system) a process we own has used, in seconds.
    public static func cpuSeconds(of pid: Int32) -> TimeInterval? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
        }
        guard ok else { return nil }
        var tb = mach_timebase_info_data_t()
        guard mach_timebase_info(&tb) == KERN_SUCCESS, tb.denom != 0 else { return nil }
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        return ticks * Double(tb.numer) / Double(tb.denom) / 1e9
    }
}

// MARK: - Keep-awake guard

/// When an ordinary keep-awake should stop by itself to save the battery.
public struct KeepAwakeGuard: Equatable, Codable, Sendable {
    public var stopOnBattery: Bool
    /// Stop when the battery falls to this percent (0 = never).
    public var stopBelowPercent: Int

    public init(stopOnBattery: Bool = false, stopBelowPercent: Int = 15) {
        self.stopOnBattery = stopOnBattery
        self.stopBelowPercent = stopBelowPercent
    }

    /// Why to stop now, or nil to keep going.
    public func reason(onBattery: Bool, batteryPercent: Int?) -> String? {
        guard onBattery else { return nil }
        if stopOnBattery { return "your Mac was unplugged" }
        if stopBelowPercent > 0, let p = batteryPercent, p <= stopBelowPercent { return "the battery is at \(p)%" }
        return nil
    }
}

// MARK: - Privacy log

/// A record of when the mic and camera turned on and off. Kept on this Mac only.
public struct PrivacyEvent: Equatable, Codable, Identifiable, Sendable {
    public enum Device: String, Codable, Sendable { case mic, camera }
    public var date: Date
    public var device: Device
    public var on: Bool
    /// Apps using the mic, when known.
    public var apps: [String]
    public var id: String { "\(date.timeIntervalSince1970)-\(device.rawValue)-\(on)" }

    public init(date: Date, device: Device, on: Bool, apps: [String] = []) {
        self.date = date; self.device = device; self.on = on; self.apps = apps
    }
}

public struct PrivacyLog: Equatable, Codable, Sendable {
    public static let maxEvents = 500
    public private(set) var events: [PrivacyEvent] = []

    public init(events: [PrivacyEvent] = []) {
        self.events = Array(events.suffix(Self.maxEvents))
    }

    public mutating func record(_ e: PrivacyEvent) {
        events.append(e)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    /// Newest first.
    public var recent: [PrivacyEvent] { events.reversed() }

    public mutating func clear() { events = [] }

    public static let defaultURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first.map { $0.appendingPathComponent("Keepwatch/privacy-log.json") }
        ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Keepwatch/privacy-log.json")

    /// Loads a saved log; a missing, oversized or damaged file gives an empty log.
    public static func load(from url: URL = defaultURL) -> PrivacyLog {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size < 2_000_000,
              let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(PrivacyLog.self, from: data) else { return PrivacyLog() }
        return PrivacyLog(events: log.events)
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - System load

/// CPU and memory use of the whole Mac.
public struct SystemLoad: Equatable, Sendable {
    public var cpuPercent: Int?
    public var memoryPercent: Int?

    public init(cpuPercent: Int?, memoryPercent: Int?) {
        self.cpuPercent = cpuPercent; self.memoryPercent = memoryPercent
    }
}

public struct SystemLoadSampler: Sendable {
    private var lastTicks: (busy: UInt64, total: UInt64)?

    public init() {}

    public mutating func sample() -> SystemLoad {
        SystemLoad(cpuPercent: cpu(), memoryPercent: Self.memory())
    }

    private mutating func cpu() -> Int? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice, total = busy &+ idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total, busy >= last.busy else { return nil }
        return Self.percent(busy - last.busy, of: total - last.total)
    }

    static func memory() -> Int? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        // "Used" as Activity Monitor counts it: app (internal minus purgeable), wired and compressed.
        let used = UInt64(stats.internal_page_count) &- min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
            &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
        let pageSize = UInt64(vm_kernel_page_size)
        return percent(used &* pageSize, of: ProcessInfo.processInfo.physicalMemory)
    }

    static func percent(_ part: UInt64, of whole: UInt64) -> Int? {
        guard whole > 0 else { return nil }
        return Int(min(100, (Double(part) / Double(whole) * 100).rounded()))
    }
}
