import Foundation

public struct Quota: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var used: Double
    public var resetsAt: Date?
    public var observedAt: Date
    /// Seconds before a reading counts as stale. Nil means the default five minutes.
    public var maxAge: TimeInterval?
    public var remaining: Double { 100 - used }
    public var hasGhost: Bool { used >= 70 }
    /// Distance in character widths: the ghost catches up at 100%.
    public var ghostGap: Double { max(0, (100 - used) / 10) }
    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(observedAt) > (maxAge ?? 300) || (resetsAt.map { $0 <= now } ?? false)
    }
    public init(id: String, title: String, used: Double, resetsAt: Date? = nil, observedAt: Date = Date()) {
        self.id = id; self.title = title
        self.used = used.isFinite ? min(100, max(0, used)) : 0
        self.resetsAt = resetsAt; self.observedAt = observedAt
    }
}

public enum QuotaParser {
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 { return Date(timeIntervalSince1970: n) }
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
    public static func codex(_ data: Data, now: Date = Date()) throws -> [Quota] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil,
              let result = root["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else { throw ParseError.invalid }
        return ["primary", "secondary"].compactMap { key in
            guard let w = limits[key] as? [String: Any], let used = number(w["usedPercent"]),
                  (0...100).contains(used) else { return nil }
            let minutes = number(w["windowDurationMins"])
            let title = minutes.map { $0 >= 1440 ? "\(Int($0 / 1440))-day" : ($0 >= 60 ? "\(Int($0 / 60))-hour" : "\(Int($0))-minute") }
                ?? (key == "primary" ? "Primary" : "Secondary")
            return Quota(id: key, title: title, used: used, resetsAt: date(w["resetsAt"]), observedAt: now)
        }
    }
    /// Only provider-reported subscription quota is retained. Context tokens are unrelated.
    /// Claude Code calls `five_hour` the session window; per-model weekly windows arrive as
    /// `seven_day_<model>` objects or as `model_scoped` buckets with a server-supplied label.
    public static func claude(_ data: Data, now: Date = Date()) throws -> [Quota] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.invalid }
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        let windows = [("five_hour", "Session"), ("seven_day", "Weekly"),
                       ("seven_day_opus", "Opus weekly"), ("seven_day_sonnet", "Sonnet weekly")]
        var quotas: [Quota] = windows.compactMap { key, title in
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percentage"]),
                  (0...100).contains(used) else { return nil }
            return Quota(id: key, title: title, used: used, resetsAt: date(w["resets_at"]), observedAt: now)
        }
        for bucket in limits["model_scoped"] as? [[String: Any]] ?? [] {
            // Allowlist: display_name, utilization, resets_at. Utilization is a 0...1 fraction upstream.
            guard let name = (bucket["display_name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name.count <= 24, let raw = number(bucket["utilization"]) else { continue }
            let used = raw <= 1 ? raw * 100 : raw
            guard (0...100).contains(used), !quotas.contains(where: { $0.id == "model:" + name }) else { continue }
            quotas.append(Quota(id: "model:" + name, title: name + " weekly", used: used,
                                resetsAt: date(bucket["resets_at"]), observedAt: now))
        }
        return quotas
    }
    /// Per-model weekly limits (e.g. Fable) from Claude Code's cached usage snapshot in ~/.claude.json.
    /// Allowlist: cachedUsageUtilization.fetchedAtMs and limits[] rows of kind weekly_scoped
    /// (percent, resets_at, scope.model.display_name). Every other key, including account ids, is ignored.
    public static func claudeSnapshot(_ data: Data) throws -> [Quota] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.invalid }
        guard let cache = root["cachedUsageUtilization"] as? [String: Any],
              let fetched = number(cache["fetchedAtMs"]), fetched > 0,
              let usage = cache["utilization"] as? [String: Any] else { return [] }
        let observed = Date(timeIntervalSince1970: fetched / 1000)
        var quotas: [Quota] = []
        for row in usage["limits"] as? [[String: Any]] ?? [] where row["kind"] as? String == "weekly_scoped" {
            guard let scope = row["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name.count <= 24, let used = number(row["percent"]), (0...100).contains(used),
                  !quotas.contains(where: { $0.id == "model:" + name }) else { continue }
            var q = Quota(id: "model:" + name, title: name + " weekly", used: used,
                          resetsAt: date(row["resets_at"]), observedAt: observed)
            q.maxAge = 2 * 3600
            quotas.append(q)
        }
        return quotas
    }
    public enum ParseError: Error { case invalid }
}
import CoreFoundation

public enum LocalState {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenChomp", isDirectory: true)
    }
    public static var claudeFile: URL { directory.appendingPathComponent("claude.json") }
    public static func readClaude() throws -> [Quota] {
        try JSONDecoder().decode([Quota].self, from: Data(contentsOf: claudeFile))
    }
    public static var claudeCodeConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
    /// Read-only. Never written, never copied; only allowlisted fields survive parsing.
    public static func readClaudeSnapshot() throws -> [Quota] {
        try QuotaParser.claudeSnapshot(Data(contentsOf: claudeCodeConfig))
    }
    public static func saveClaude(_ incoming: [Quota]) throws {
        // The executable bridge holds a file lock around this read/merge/write.
        var merged = (try? readClaude()) ?? []
        for q in incoming {
            if let i = merged.firstIndex(where: { $0.id == q.id }) {
                if merged[i].observedAt <= q.observedAt { merged[i] = q }
            } else { merged.append(q) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(merged).write(to: claudeFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeFile.path)
    }
}
