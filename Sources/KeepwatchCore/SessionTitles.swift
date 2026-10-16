import Foundation

/// Session names for Claude Code: the title it shows in its own session list
/// (`/rename`'s custom title, else its generated title). Claude Code keeps
/// these in each session's transcript under `~/.claude/projects`. Keepwatch
/// only reads the end of that file, never keeps it, and shows the title only
/// when it can tell which transcript belongs to which session.
public enum SessionTitles {
    /// Bytes read from the end of a transcript. Titles are re-written as the
    /// session goes on, so the newest is near the end.
    static let tailBytes = 512 * 1024
    static let maxTitleLength = 80

    /// `--session-id <uuid>` or `--resume <uuid>` from Claude Code's arguments.
    public static func sessionID(fromArguments args: [String]) -> String? {
        for (i, arg) in args.enumerated() where arg == "--session-id" || arg == "--resume" || arg == "-r" {
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
                                .appendingPathComponent(".claude/projects")) -> [Int32: String] {
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
