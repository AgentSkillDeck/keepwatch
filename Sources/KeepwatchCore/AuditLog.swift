import Foundation

/// Keepwatch's own activity log: every change it makes to the Mac or to
/// other apps (sleep settings, lid sessions, the mic, quitting apps, stopping
/// processes, Mac tweaks, updates, permissions it asks for), so you can check
/// what it did and when. Local only: never sent anywhere. Capped, readable by
/// you alone (0600), and lenient when the file is damaged.
public struct AuditLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var date: Date
        public var action: String
        public var detail: String
        public var id: String { "\(date.timeIntervalSince1970)-\(action)-\(detail)" }

        public init(date: Date, action: String, detail: String) {
            self.date = date
            self.action = action
            self.detail = detail
        }
    }

    public static let maxEntries = 1_000
    static let maxTextLength = 300
    static let maxFileBytes = 4 * 1024 * 1024

    /// Oldest first.
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.suffix(Self.maxEntries))
    }

    /// One line, no control characters, capped length: log text can come from
    /// app or process names, which other software controls.
    static func clean(_ s: String) -> String {
        let flat = String(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        return flat.count > maxTextLength ? String(flat.prefix(maxTextLength - 1)) + "…" : flat
    }

    public mutating func append(_ action: String, _ detail: String = "", at date: Date = Date()) {
        entries.append(Entry(date: date, action: Self.clean(action), detail: Self.clean(detail)))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    public mutating func clear() { entries = [] }

    /// Newest first, `size` per page; a page past the end shows the last one.
    public func page(_ index: Int, size: Int) -> [Entry] {
        guard size > 0, !entries.isEmpty else { return [] }
        let newest = Array(entries.reversed())
        let pages = (newest.count + size - 1) / size
        let i = min(max(0, index), pages - 1)
        return Array(newest.dropFirst(i * size).prefix(size))
    }

    public func pageCount(size: Int) -> Int { size > 0 ? (entries.count + size - 1) / size : 0 }

    /// Plain text, one entry per line, for copying or a bug report.
    public func text() -> String {
        let f = ISO8601DateFormatter()
        return entries.map { "\(f.string(from: $0.date))  \($0.action)\($0.detail.isEmpty ? "" : ": \($0.detail)")" }
            .joined(separator: "\n")
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Keepwatch", isDirectory: true).appendingPathComponent("activity-log.json")
    }

    /// An unreadable, oversized or damaged file gives an empty log, not a crash.
    public static func load(from url: URL = defaultURL()) -> AuditLog {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil,
              size <= maxFileBytes, let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(AuditLog.self, from: data) else { return AuditLog() }
        return AuditLog(entries: log.entries)
    }

    @discardableResult
    public func save(to url: URL = defaultURL()) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}
