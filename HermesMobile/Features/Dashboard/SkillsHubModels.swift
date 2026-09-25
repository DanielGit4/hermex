import Foundation

/// One `GET /api/skills` row. `provenance` is where the skill came from: `hub` (installed
/// from the Skills Hub, the only kind `hermes skills uninstall` removes), `bundled` (ships
/// with Hermes) or `agent` (written by the agent or by hand on the host). The contract has
/// no version and no update-available flag, so rows show provenance and hub trust instead,
/// and Update is the host's global `hermes skills update`.
struct DashboardSkill: Identifiable, Hashable {
    let name: String
    let description: String?
    let category: String?
    let enabled: Bool
    let provenance: String?

    var id: String { name }
    var isFromHub: Bool { provenance == "hub" }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text.trimmedNonEmpty else { return nil }
        self.name = name
        description = row["description"].text.trimmedNonEmpty
        category = row["category"].text.trimmedNonEmpty
        enabled = row["enabled"].flag ?? true
        provenance = row["provenance"].text.trimmedNonEmpty
    }
}

/// The host's `GET /api/skills/content` response for an installed skill.
struct DashboardSkillContent: Hashable {
    let name: String
    let markdown: String
    let path: String?

    init?(_ json: BotJSON) {
        guard let name = json["name"].text.trimmedNonEmpty,
              let content = json["content"].text else { return nil }
        self.name = name
        markdown = SkillMarkdown.withoutFrontMatter(content)
        path = json["path"].text.trimmedNonEmpty
    }
}

/// SKILL.md files are YAML-front-matter documents, not Markdown documents from line one.
enum SkillMarkdown {
    static func withoutFrontMatter(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closingFence = lines.dropFirst().firstIndex(where: {
                  let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  return line == "---" || line == "..."
              }) else { return markdown }
        return lines.dropFirst(closingFence + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One hub lock entry, keyed by the identifier the skill was installed from.
struct HubLockEntry: Hashable {
    let name: String?
    let trustLevel: String?
    let scanVerdict: String?

    init(_ entry: BotJSON) {
        name = entry["name"].text.trimmedNonEmpty
        trustLevel = entry["trust_level"].text.trimmedNonEmpty
        scanVerdict = entry["scan_verdict"].text.trimmedNonEmpty
    }

    /// Nil when the host left the map out, so a caller can keep what it already knows.
    static func entries(_ json: BotJSON) -> [String: HubLockEntry]? {
        guard let fields = json.fields else { return nil }
        return fields.reduce(into: [:]) { entries, pair in
            if pair.value.fields != nil { entries[pair.key] = HubLockEntry(pair.value) }
        }
    }
}

/// A Skills Hub search result, and the listing half of a preview.
struct HubSkill: Identifiable, Hashable {
    let identifier: String
    let name: String
    let description: String?
    let source: String?
    let trustLevel: String?
    let repo: String?
    let tags: [String]

    var id: String { identifier }

    init?(_ row: BotJSON, identifier fallback: String? = nil) {
        guard let identifier = row["identifier"].text.trimmedNonEmpty ?? fallback.trimmedNonEmpty else { return nil }
        self.identifier = identifier
        name = row["name"].text.trimmedNonEmpty ?? identifier
        description = row["description"].text.trimmedNonEmpty
        source = row["source"].text.trimmedNonEmpty
        trustLevel = row["trust_level"].text.trimmedNonEmpty
        repo = row["repo"].text.trimmedNonEmpty
        tags = (row["tags"].list ?? []).compactMap { $0.text.trimmedNonEmpty }
    }
}

struct HubSearchResult: Hashable {
    let results: [HubSkill]
    /// The hub lock as of this search; nil when the host left it out.
    let installed: [String: HubLockEntry]?
    /// Hub sources that did not answer inside the host's search budget.
    let timedOut: [String]

    init(_ json: BotJSON) {
        results = (json["results"].list ?? []).compactMap { HubSkill($0) }
        installed = HubLockEntry.entries(json["installed"])
        timedOut = (json["timed_out"].list ?? []).compactMap { $0.text.trimmedNonEmpty }
    }
}

/// A hub skill's SKILL.md and file list, read without installing it.
struct HubSkillPreview: Hashable {
    let skill: HubSkill
    let skillMarkdown: String?
    let files: [String]

    init?(_ json: BotJSON, identifier: String) {
        guard json.fields != nil, let skill = HubSkill(json, identifier: identifier) else { return nil }
        self.skill = skill
        skillMarkdown = json["skill_md"].text.map(SkillMarkdown.withoutFrontMatter).trimmedNonEmpty
        files = (json["files"].list ?? []).compactMap { $0.text.trimmedNonEmpty }
    }
}

/// The install-time security scan of a hub skill, run by the host on a quarantined copy.
struct HubSkillScan: Hashable {
    /// What the host's install policy decides for this verdict and trust level. The
    /// dashboard install never forces, so only `allow` installs: `ask` and `block` refuse.
    enum Policy: String { case allow, ask, block }

    struct Finding: Hashable {
        let severity: String?
        let category: String?
        let file: String?
        let line: Int?
        let description: String?
    }

    struct SeverityCounts: Hashable {
        let critical: Int, high: Int, medium: Int, low: Int
        var total: Int { critical + high + medium + low }
    }

    let verdict: String?
    let summary: String?
    let source: String?
    let trustLevel: String?
    let policy: Policy?
    let policyReason: String?
    let findings: [Finding]
    let severityCounts: SeverityCounts
    /// The optional SkillEvaluator second opinion; nil when the host does not run it.
    let advisoryPassed: Bool?
    let advisoryFindingCount: Int?

    init(_ json: BotJSON) {
        verdict = json["verdict"].text.trimmedNonEmpty
        summary = json["summary"].text.trimmedNonEmpty
        source = json["source"].text.trimmedNonEmpty
        trustLevel = json["trust_level"].text.trimmedNonEmpty
        policy = json["policy"].text.flatMap(Policy.init(rawValue:))
        policyReason = json["policy_reason"].text.trimmedNonEmpty
        findings = (json["findings"].list ?? []).compactMap { row in
            guard row.fields != nil else { return nil }
            return Finding(severity: row["severity"].text.trimmedNonEmpty, category: row["category"].text.trimmedNonEmpty,
                           file: row["file"].text.trimmedNonEmpty, line: row["line"].integer,
                           description: row["description"].text.trimmedNonEmpty)
        }
        let counts = json["severity_counts"]
        severityCounts = SeverityCounts(critical: counts["critical"].integer ?? 0, high: counts["high"].integer ?? 0,
                                        medium: counts["medium"].integer ?? 0, low: counts["low"].integer ?? 0)
        let advisory = json["tier1"]
        advisoryPassed = advisory["passed"].flag
        advisoryFindingCount = advisory["findings"].list?.count
    }

    /// Installation is enabled only when the host explicitly allows it.
    var allowsInstall: Bool { policy == .allow }
}

/// `GET /api/actions/{name}/status` for a spawned install, uninstall or update.
struct DashboardActionStatus: Hashable {
    let running: Bool
    /// Nil while running, and when the host cannot say how a finished action ended.
    let exitCode: Int?
    /// This run's lines from the tail of the action's log on the host.
    let lines: [String]

    init(_ json: BotJSON) {
        running = json["running"].flag ?? false
        exitCode = json["exit_code"].integer
        lines = Self.currentRun((json["lines"].list ?? []).compactMap(\.text))
    }

    /// The host appends every run of an action to one log, opening each with an
    /// `=== <name> started <time> ===` line, so this run is what follows the last one.
    static func currentRun(_ lines: [String]) -> [String] {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("=== ") && $0.contains(" started ") }) else { return lines }
        return Array(lines[lines.index(after: start)...])
    }
}

private extension Optional where Wrapped == String {
    /// The trimmed text, or nil when absent or blank.
    var trimmedNonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
