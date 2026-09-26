import Foundation

/// One `GET /api/dashboard/plugins/hub` row (`_merged_plugins_hub` on the host). Every field
/// but the name is optional, so a row with nothing else still lists and opens.
struct AgentPlugin: Identifiable, Hashable {
    /// The host's key, sent back as sent when addressing it. Nested keys contain `/`.
    let name: String
    let version: String?
    let description: String?
    /// `bundled`, `user`, `git` or `entrypoint` at the pin; a newer value shows as sent.
    let source: String?
    /// `enabled`, `disabled` or `inactive` (installed, never enabled); a newer value shows as sent.
    var runtimeStatus: String?
    /// Where it lives on the host, shown small.
    let path: String?
    /// Only plugins in the host's `~/.hermes/plugins` folder.
    let canRemove: Bool
    let canUpdateGit: Bool
    let authRequired: Bool
    /// What to run in a terminal on the host to sign the plugin in.
    let authCommand: String?
    /// Why the catalog's kill list pulled it, when it did.
    let removedReason: String?

    var id: String { name }
    var isEnabled: Bool { runtimeStatus == "enabled" }
    var isBundled: Bool { source == "bundled" }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        self.name = name
        version = row["version"].text.trimmedNonEmpty
        description = row["description"].text.trimmedNonEmpty
        source = row["source"].text.trimmedNonEmpty
        runtimeStatus = row["runtime_status"].text.trimmedNonEmpty
        path = row["path"].text.trimmedNonEmpty
        canRemove = row["can_remove"].flag ?? false
        canUpdateGit = row["can_update_git"].flag ?? false
        authRequired = row["auth_required"].flag ?? false
        authCommand = row["auth_command"].text.trimmedNonEmpty
        removedReason = row["removed_reason"].text.trimmedNonEmpty
    }
}

/// `GET /api/dashboard/plugins/catalog`: the live curated catalog with this host's install
/// state, and the plugins the catalog has pulled.
struct PluginCatalog: Hashable {
    struct Removal: Hashable {
        let name: String
        let repo: String?
        let reason: String?
        let date: String?
    }

    var entries: [PluginCatalogEntry] = []
    var removed: [Removal] = []

    init() {}

    init?(_ json: BotJSON) {
        guard json.fields != nil else { return nil }
        entries = (json["entries"].list ?? []).compactMap(PluginCatalogEntry.init)
        removed = (json["removed"].list ?? []).compactMap { row in
            guard let name = row["name"].text.trimmedNonEmpty else { return nil }
            return Removal(name: name, repo: row["repo"].text.trimmedNonEmpty, reason: row["reason"].text.trimmedNonEmpty,
                           date: row["date"].text.trimmedNonEmpty)
        }
    }

    func entry(named name: String) -> PluginCatalogEntry? { entries.first { $0.name == name } }

    /// The entry an installed plugin came from. The host links them only by name, so it is an
    /// installed entry named like the plugin or like the last part of a nested key.
    func entry(installedAs name: String) -> PluginCatalogEntry? {
        let leaf = name.split(separator: "/").last.map(String.init) ?? name
        return entries.first { $0.installed && ($0.name == name || $0.name == leaf) }
    }

    /// Why the catalog pulled an entry, matched by name or repository.
    func removal(for entry: PluginCatalogEntry) -> Removal? {
        removed.first { $0.name == entry.name || ($0.repo != nil && $0.repo == entry.repo) }
    }
}

/// One catalog entry (`PluginCatalogEntry.to_dict` plus install state). Everything an install
/// fetches and registers on the host is here to review before installing.
struct PluginCatalogEntry: Identifiable, Hashable {
    struct Capabilities: Hashable {
        var tools: [String] = []
        var hooks: [String] = []
        var middleware: [String] = []
        /// Names only; values are set on the host.
        var requiredEnv: [String] = []
    }

    /// The catalog key the install sends; the installed plugin may be named differently.
    let name: String
    /// As sent, or nil when empty; screens use `displayTitle`.
    let title: String?
    let description: String?
    let repo: String?
    let sha: String?
    let shaShort: String?
    let version: String?
    let subdir: String?
    let maintainer: String?
    /// `official` or `community` at the pin; a newer value shows as sent.
    let tier: String?
    let category: String?
    let requiresHermes: String?
    let docsURL: String?
    /// Empty means every platform.
    let platforms: [String]
    let capabilities: Capabilities
    let capabilitySummary: String?
    let installed: Bool
    let installedSHA: String?
    let updateAvailable: Bool
    let runtimeStatus: String?

    var id: String { name }
    var displayTitle: String { title ?? PluginLabels.title(fromName: name) }

    /// `version @ sha_short`, the pin a review names.
    var pin: String? {
        switch (version, shaShort) {
        case let (version?, sha?): return "\(version) @ \(sha)"
        case let (version?, nil): return version
        case let (nil, sha?): return sha
        case (nil, nil): return nil
        }
    }

    /// Only an https link opens; anything else shows as text.
    var docsLink: URL? {
        guard let docsURL, let url = URL(string: docsURL), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text.trimmedNonEmpty else { return nil }
        self.name = name
        title = row["title"].text.trimmedNonEmpty
        description = row["description"].text.trimmedNonEmpty
        repo = row["repo"].text.trimmedNonEmpty
        sha = row["sha"].text.trimmedNonEmpty
        shaShort = row["sha_short"].text.trimmedNonEmpty ?? sha.map { String($0.prefix(7)) }
        version = row["version"].text.trimmedNonEmpty
        subdir = row["subdir"].text.trimmedNonEmpty
        maintainer = row["maintainer"].text.trimmedNonEmpty
        tier = row["tier"].text.trimmedNonEmpty
        category = row["category"].text.trimmedNonEmpty
        requiresHermes = row["requires_hermes"].text.trimmedNonEmpty
        docsURL = row["docs_url"].text.trimmedNonEmpty
        platforms = PluginText.list(row["platforms"])
        let capabilities = row["capabilities"]
        self.capabilities = Capabilities(tools: PluginText.list(capabilities["provides_tools"]),
                                         hooks: PluginText.list(capabilities["provides_hooks"]),
                                         middleware: PluginText.list(capabilities["provides_middleware"]),
                                         requiredEnv: PluginText.list(capabilities["requires_env"]))
        capabilitySummary = row["capability_summary"].text.trimmedNonEmpty
        installed = row["installed"].flag ?? false
        installedSHA = row["installed_sha"].text.trimmedNonEmpty
        updateAvailable = row["update_available"].flag ?? false
        runtimeStatus = row["runtime_status"].text.trimmedNonEmpty
    }
}

/// Whether a change is live: loaded now, after a restart, in new sessions, or not at all
/// because the plugin isn't enabled.
enum PluginLiveness: Hashable {
    case activeNow, restartRequired, newSessions, notEnabled

    init(_ json: BotJSON, enabled: Bool = true) {
        if !enabled {
            self = .notEnabled
        } else if json["restart_required"].flag == true {
            self = .restartRequired
        } else if json["gateway_reloaded"].flag == true {
            self = .activeNow
        } else {
            self = .newSessions
        }
    }
}

/// `POST /api/dashboard/agent-plugins/install`'s 200 answer. `ok` alone is not success: the
/// caller confirms it against a fresh hub read.
struct PluginInstallResult: Hashable {
    /// The installed name, which may differ from the catalog name.
    let pluginName: String?
    let warnings: [String]
    let pythonDependencies: [String]
    /// Names to set on the host before the plugin works; the host never sends values.
    let missingEnv: [String]
    let liveness: PluginLiveness

    init?(_ json: BotJSON) {
        guard json["ok"].flag == true else { return nil }
        pluginName = json["plugin_name"].text.trimmedNonEmpty
        warnings = PluginText.list(json["warnings"])
        pythonDependencies = PluginText.list(json["python_dependencies"])
        missingEnv = PluginText.list(json["missing_env"])
        liveness = PluginLiveness(json, enabled: json["enabled"].flag ?? true)
    }
}

/// `POST …/{name}/enable` or `/disable`. It carries no status: a fresh hub read shows that.
struct PluginToggleResult: Hashable {
    let unchanged: Bool
    /// For an enable, whether it went live. A disable is config-only until Hermes restarts.
    let liveness: PluginLiveness

    init?(_ json: BotJSON) {
        guard json["ok"].flag == true else { return nil }
        unchanged = json["unchanged"].flag ?? false
        liveness = PluginLiveness(json)
    }
}

/// `POST …/{name}/update`: a catalog plugin re-pins to the catalog's commit, any other git
/// plugin pulls. A re-pin that widens what the plugin may do changes nothing and answers
/// 200 with `consent_required`.
enum PluginUpdateAnswer: Hashable {
    case updated(PluginUpdate)
    case needsConsent(PluginConsent)

    init?(_ json: BotJSON) {
        if json["consent_required"].flag == true {
            self = .needsConsent(PluginConsent(json))
            return
        }
        guard json["ok"].flag == true else { return nil }
        let unchanged = json["unchanged"].flag ?? false
        let sha = json["sha"].text.trimmedNonEmpty
        self = .updated(PluginUpdate(sha: sha, output: json["output"].text.trimmedNonEmpty, unchanged: unchanged,
                                     liveness: sha == nil || unchanged ? nil : PluginLiveness(json),
                                     warnings: PluginText.list(json["warnings"]),
                                     pythonDependencies: PluginText.list(json["python_dependencies"])))
    }
}

/// A finished update: a re-pin names its new commit, a git pull its output.
struct PluginUpdate: Hashable {
    let sha: String?
    let output: String?
    let unchanged: Bool
    /// Nil when nothing was reloaded, as after a git pull: the new code loads in new sessions.
    let liveness: PluginLiveness?
    let warnings: [String]
    let pythonDependencies: [String]
}

/// What a re-pin would add, shown as the host words it before anything is sent again.
struct PluginConsent: Hashable {
    let message: String?
    let sha: String?
    let deltaLines: [String]

    var shortSHA: String? { sha.map { String($0.prefix(7)) } }

    init(_ json: BotJSON) {
        message = json["error"].text.trimmedNonEmpty
        sha = json["sha"].text.trimmedNonEmpty
        let lines = PluginText.list(json["delta_lines"])
        // An older answer without `delta_lines` still lists each added capability.
        deltaLines = lines.isEmpty
            ? (json["delta"].fields ?? [:]).sorted { $0.key < $1.key }.compactMap { key, value in
                let names = PluginText.list(value)
                return names.isEmpty ? nil : "\(key): \(names.joined(separator: ", "))"
            }
            : lines
    }
}

/// `DELETE …/{name}`'s answer.
struct PluginRemoveResult: Hashable {
    /// The host's memory provider pointed at this plugin and was reset.
    let clearedMemoryProvider: Bool

    init?(_ json: BotJSON) {
        guard json["ok"].flag == true else { return nil }
        clearedMemoryProvider = json["cleared_memory_provider"].flag ?? false
    }
}

/// An install the host's security scan blocked. At the pin the refusal's `detail` is the whole
/// report as text; a newer host may send the verdict and findings as fields instead.
struct PluginScanBlock: Hashable {
    struct Finding: Hashable {
        let severity: String?
        let category: String?
        let patternID: String?
        let file: String?
        let line: Int?
        let description: String?
    }

    /// The host's report, shown as sent.
    let report: String?
    let verdict: String?
    let findings: [Finding]

    init?(_ detail: BotJSON) {
        let text = detail.text ?? detail["error"].text
        let saysBlocked = text?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Security scan blocked") == true
        guard saysBlocked || detail["scan_blocked"].flag == true else { return nil }
        report = text.trimmedNonEmpty
        verdict = detail["scan_verdict"].text.trimmedNonEmpty
        findings = (detail["scan_findings"].list ?? []).compactMap { row in
            guard row.fields != nil else { return nil }
            return Finding(severity: row["severity"].text.trimmedNonEmpty, category: row["category"].text.trimmedNonEmpty,
                           patternID: row["pattern_id"].text.trimmedNonEmpty, file: row["file"].text.trimmedNonEmpty,
                           line: row["line"].integer, description: row["description"].text.trimmedNonEmpty)
        }
    }
}

private enum PluginText {
    /// The non-blank strings of a list; anything else is an empty list.
    static func list(_ json: BotJSON) -> [String] {
        (json.list ?? []).compactMap { $0.text.trimmedNonEmpty }
    }
}

/// Display names for the host's plugin vocabulary; unknown values from a newer host show as sent.
enum PluginLabels {
    static func source(_ value: String?) -> String {
        switch value {
        case "bundled"?: return String(localized: "Bundled")
        case "user"?: return String(localized: "Local")
        case "git"?: return "Git"
        case "entrypoint"?: return String(localized: "Python package")
        case nil: return String(localized: "Unknown source")
        case let value?: return value
        }
    }

    static func status(_ value: String?) -> String {
        switch value {
        case "enabled"?: return String(localized: "Enabled")
        case "disabled"?: return String(localized: "Disabled")
        case "inactive"?: return String(localized: "Not enabled")
        case nil: return String(localized: "Unknown status")
        case let value?: return value
        }
    }

    static func tier(_ value: String?) -> String? {
        switch value {
        case "official"?: return String(localized: "Official")
        case "community"?: return String(localized: "Community")
        case let value: return value
        }
    }

    /// Who stands behind an entry. The community wording is a safety requirement.
    static func tierNote(_ value: String?) -> String? {
        switch value {
        case "official"?: return String(localized: "Maintained by Nous Research.")
        case "community"?:
            return String(localized: "Community-maintained: not written or maintained by Nous Research. Reviewed at this exact commit only.")
        default: return nil
        }
    }

    static func platforms(_ values: [String]) -> String {
        guard !values.isEmpty else { return String(localized: "All platforms") }
        return values.map { value in
            switch value.lowercased() {
            case "macos", "darwin": return "macOS"
            case "linux": return "Linux"
            case "windows", "win32": return "Windows"
            default: return value
            }
        }.joined(separator: ", ")
    }

    static func liveness(_ value: PluginLiveness) -> String {
        switch value {
        case .activeNow: return String(localized: "Active now.")
        case .restartRequired: return String(localized: "Restart required: it takes effect after Hermes restarts.")
        case .newSessions: return String(localized: "It loads in new sessions and after Hermes restarts.")
        case .notEnabled: return String(localized: "Installed, not enabled.")
        }
    }

    /// A catalog name as words: `-` and `_` become spaces and each word starts uppercase.
    static func title(fromName name: String) -> String {
        let words = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? name : words.joined(separator: " ")
    }
}
