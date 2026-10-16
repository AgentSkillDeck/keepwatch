import Foundation

/// Session names, as the agent shows them in its own session list.
/// - Claude Code: `/rename`'s custom title, else its generated title, from the
///   end of the session's transcript under `~/.claude/projects`.
/// - Codex: the thread name in `~/.codex/session_index.jsonl`, matched to the
///   running session through the first line of its rollout file under
///   `~/.codex/sessions` (which records the folder it runs in).
/// Keepwatch only reads small parts of these files, never keeps them, and
/// shows a name only when it can tell which file belongs to which session.
public enum SessionTitles {
    /// Bytes read from the end of a transcript. Titles are re-written as the
    /// session goes on, so the newest is near the end.
    static let tailBytes = 512 * 1024
    static let maxTitleLength = 80

    /// `--session-id <uuid>` or `--resume <uuid>` from Claude Code's arguments.
    public static func sessionID(fromArguments args: [String]) -> String? {
        for (i, arg) in args.enumerated() where arg == "--session-id" || arg == "--resume" || arg == "-r" || arg == "resume" {
            guard let next = args.dropFirst(i + 1).first, isUUID(next) else { continue }
            return next.lowercased()
        }
        for arg in args where arg.hasPrefix("--session-id=") {
            let value = String(arg.dropFirst("--session-id=".count))
            if isUUID(value) { return value.lowercased() }
        }
        return nil
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// Claude Code's folder name for a working directory: every character
    /// that isn't a letter or digit becomes "-".
    public static func projectDirName(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The newest custom title in `text`, else the newest generated title.
    /// `text` is JSON lines, possibly cut mid-line at the start.
    public static func title(inTranscriptTail text: Substring) -> String? {
        var custom: String?
        var generated: String?
        for line in text.split(separator: "\n") {
            if line.contains("\"type\":\"custom-title\""), let t = value(of: "customTitle", in: line) { custom = t }
            if line.contains("\"type\":\"ai-title\""), let t = value(of: "aiTitle", in: line) { generated = t }
        }
        return (custom ?? generated).map(clean)
    }

    /// Reads `key` from one JSON line; nil if the line isn't valid JSON.
    static func value(of key: String, in line: Substring) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String else { return nil }
        return value
    }

    /// Turns "fix-login-redirect" into "fix login redirect", trims and caps it.
    static func clean(_ title: String) -> String {
        let spaced = title.contains(" ") ? title : title.replacingOccurrences(of: "-", with: " ")
        let trimmed = spaced.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.count > maxTitleLength ? String(trimmed.prefix(maxTitleLength - 1)) + "…" : trimmed
    }

    /// The title of session `id` started in `cwd`, read from disk.
    public static func title(sessionID id: String, cwd: String,
                             projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".claude/projects")) -> String? {
        let file = projectsDir.appendingPathComponent(projectDirName(for: cwd))
            .appendingPathComponent("\(id).jsonl")
        guard let tail = readTail(of: file) else { return nil }
        return title(inTranscriptTail: tail[...])
    }

    /// Names for Claude Code sessions, by pid. A session without an id in its
    /// arguments gets the newest transcript in its folder that started after
    /// it, but only when it is the only such session there; otherwise it would
    /// be a guess, and no name is better than a wrong one.
    public static func titles(for sessions: [AgentSession],
                              projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".claude/projects"),
                              codexDir: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".codex"),
                              now: Date = Date()) -> [Int32: String] {
        claudeTitles(for: sessions, projectsDir: projectsDir)
            .merging(codexTitles(for: sessions, codexDir: codexDir, now: now)) { a, _ in a }
    }

    static func claudeTitles(for sessions: [AgentSession], projectsDir: URL) -> [Int32: String] {
        let claude = sessions.filter { $0.agent == "Claude Code" && $0.folder != nil }
        let known = Set(claude.compactMap(\.sessionID))
        let idless = Dictionary(grouping: claude.filter { $0.sessionID == nil }, by: { $0.folder ?? "" })
        var result: [Int32: String] = [:]
        for s in claude {
            guard let cwd = s.folder else { continue }
            var id = s.sessionID
            if id == nil, idless[cwd]?.count == 1 {
                id = newestTranscript(in: projectsDir.appendingPathComponent(projectDirName(for: cwd)),
                                      since: s.started, excluding: known)
            }
            if let id, let t = title(sessionID: id, cwd: cwd, projectsDir: projectsDir) { result[s.pid] = t }
        }
        return result
    }

    // MARK: Codex

    /// id → thread name from the end of `session_index.jsonl` (newest wins).
    static func codexIndex(_ codexDir: URL) -> [String: String] {
        guard let tail = readTail(of: codexDir.appendingPathComponent("session_index.jsonl")) else { return [:] }
        var names: [String: String] = [:]
        for line in tail.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String, !name.isEmpty else { continue }
            names[id.lowercased()] = clean(name)
        }
        return names
    }

    /// Rollout files from the last few days' folders (sessions/YYYY/MM/DD),
    /// newest first, with the session id and folder from their first line.
    static func codexRollouts(_ codexDir: URL, now: Date, days: Int = 3) -> [(id: String, cwd: String, modified: Date)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var found: [(id: String, cwd: String, modified: Date)] = []
        for back in 0..<max(1, min(days, 14)) {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let dir = codexDir.appendingPathComponent("sessions")
                .appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d))
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { continue }
            for file in files.prefix(maxListed) where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate,
                      let meta = firstLine(of: file), let data = meta.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = o["payload"] as? [String: Any],
                      let id = (payload["id"] ?? payload["session_id"]) as? String,
                      let cwd = payload["cwd"] as? String else { continue }
                found.append((id.lowercased(), cwd, modified))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// The first line of a file, read 64 KB at most.
    static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    static func codexTitles(for sessions: [AgentSession], codexDir: URL, now: Date) -> [Int32: String] {
        let codex = sessions.filter { $0.agent == "Codex" && $0.folder != nil }
        guard !codex.isEmpty else { return [:] }
        let names = codexIndex(codexDir)
        guard !names.isEmpty else { return [:] }
        let known = Set(codex.compactMap(\.sessionID))
        let perFolder = Dictionary(grouping: codex.filter { $0.sessionID == nil }, by: { $0.folder ?? "" })
        let rollouts = perFolder.isEmpty ? [] : codexRollouts(codexDir, now: now)
        var result: [Int32: String] = [:]
        for s in codex {
            guard let cwd = s.folder else { continue }
            var id = s.sessionID
            if id == nil, perFolder[cwd]?.count == 1 {
                id = rollouts.first { r in
                    r.cwd == cwd && !known.contains(r.id) && (s.started.map { r.modified >= $0 } ?? true)
                }?.id
            }
            if let id, let name = names[id] { result[s.pid] = name }
        }
        return result
    }

    static let maxListed = 2_000

    /// The id of the most recently written transcript in `dir` changed since
    /// `since`, skipping ids that belong to other sessions.
    static func newestTranscript(in dir: URL, since: Date?, excluding: Set<String>) -> String? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else {
            return nil
        }
        var best: (id: String, date: Date)?
        for file in files.prefix(maxListed) where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent.lowercased()
            guard isUUID(id), !excluding.contains(id),
                  let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate else { continue }
            if let since, date < since { continue }
            if best == nil || date > (best?.date ?? .distantPast) { best = (id, date) }
        }
        return best?.id
    }

    /// The last `tailBytes` of a file as text; nil if it can't be read.
    static func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: tailBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
