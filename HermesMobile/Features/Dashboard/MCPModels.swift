import Foundation

/// One `GET /api/mcp/servers` row (`_mcp_server_summary` on the host). Env values arrive
/// already redacted (`abcd...wxyz`, `***` or empty) and are shown exactly as sent. A server
/// a plugin provides is read-only: the host refuses to toggle or delete it.
struct MCPServer: Identifiable, Hashable {
    struct EnvVariable: Hashable, Identifiable {
        let name: String
        let redactedValue: String
        var id: String { name }
    }

    /// The host's key for the server, sent back as sent when addressing it.
    let name: String
    /// `http`, `stdio` or `unknown` at the pin; a newer value shows as sent.
    let transport: String
    let url: String?
    let command: String?
    let args: [String]
    let env: [EnvVariable]
    /// `oauth`, `header` (an Authorization header is configured) or nil.
    let auth: String?
    var enabled: Bool
    let toolFilter: MCPToolFilter
    /// The plugin providing this server, when the host names it.
    let plugin: String?
    let isFromPlugin: Bool

    var id: String { name }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        self.name = name
        url = row["url"].text.trimmedNonEmpty
        command = row["command"].text.trimmedNonEmpty
        transport = row["transport"].text.trimmedNonEmpty ?? "unknown"
        args = (row["args"].list ?? []).compactMap(\.text)
        env = (row["env"].fields ?? [:])
            .map { EnvVariable(name: $0.key, redactedValue: $0.value.text ?? "") }
            .sorted { $0.name < $1.name }
        auth = row["auth"].text.trimmedNonEmpty
        enabled = row["enabled"].flag ?? true
        toolFilter = MCPToolFilter(row["tools"])
        plugin = row["plugin"].text.trimmedNonEmpty
        isFromPlugin = row["source"].text == "plugin" || plugin != nil
    }
}

/// A server's raw `tools` config, which decides the tools new sessions register. The host
/// writes `{include: [...]}` or `{exclude: [...]}` (names or globs, include winning), and
/// older configs hold a plain list. Nothing here ever fails a row.
enum MCPToolFilter: Hashable {
    /// No filter: every tool the server offers.
    case all
    /// Only these names or globs; an empty list registers none.
    case include([String])
    /// Every tool except these names or globs.
    case exclude([String])
    /// A shape this build can't read.
    case custom

    init(_ json: BotJSON) {
        switch json {
        case .null:
            self = .all
        case .array:
            self = Self.names(json).map(Self.include) ?? .custom
        case .object:
            if json["include"] != .null {
                self = Self.names(json["include"]).map(Self.include) ?? .custom
            } else if json["exclude"] != .null {
                self = Self.names(json["exclude"]).map(Self.exclude) ?? .custom
            } else {
                self = .all
            }
        default:
            self = .custom
        }
    }

    /// A list of strings, or the single string the host also accepts.
    private static func names(_ json: BotJSON) -> [String]? {
        if let name = json.text { return [name] }
        guard let list = json.list else { return nil }
        let names = list.compactMap(\.text)
        return names.count == list.count ? names : nil
    }
}

/// `POST /api/mcp/servers/{name}/test`. A probe that fails still answers 200, with the
/// host's already-redacted error.
enum MCPTestResult: Hashable {
    case connected(tools: [MCPTool], prompts: Int, resources: Int)
    case failed(error: String?)

    init?(_ json: BotJSON) {
        switch json["ok"].flag {
        case true?:
            self = .connected(tools: (json["tools"].list ?? []).compactMap(MCPTool.init),
                              prompts: json["prompts"].integer ?? 0, resources: json["resources"].integer ?? 0)
        case false?:
            self = .failed(error: json["error"].text.trimmedNonEmpty)
        case nil:
            return nil
        }
    }
}

struct MCPTool: Hashable {
    let name: String
    let description: String?
    /// The size of the tool's input schema, when the host measured it.
    let schemaCharacters: Int?

    init?(_ row: BotJSON) {
        guard let name = row["name"].text.trimmedNonEmpty else { return nil }
        self.name = name
        description = row["description"].text.trimmedNonEmpty
        schemaCharacters = row["schema_chars"].integer
    }
}

/// `GET /api/mcp/catalog`: the host's approved MCP manifests, and the ones it skipped.
struct MCPCatalog: Hashable {
    struct Diagnostic: Hashable {
        let name: String?
        /// `future_manifest` or `invalid` at the pin.
        let kind: String?
        let message: String?
    }

    let entries: [MCPCatalogEntry]
    let diagnostics: [Diagnostic]

    init?(_ json: BotJSON) {
        guard json.fields != nil else { return nil }
        entries = (json["entries"].list ?? []).compactMap(MCPCatalogEntry.init)
        diagnostics = (json["diagnostics"].list ?? []).compactMap { row in
            let diagnostic = Diagnostic(name: row["name"].text.trimmedNonEmpty, kind: row["kind"].text.trimmedNonEmpty,
                                        message: row["message"].text.trimmedNonEmpty)
            return diagnostic.name == nil && diagnostic.message == nil ? nil : diagnostic
        }
    }
}

/// One catalog manifest (`_catalog_entry_json`). Everything an install runs on the host —
/// command, args, url, the git repository and its bootstrap commands — is here to review
/// before installing.
struct MCPCatalogEntry: Identifiable, Hashable {
    struct EnvRequirement: Hashable, Identifiable {
        let name: String
        let prompt: String?
        let isRequired: Bool
        var id: String { name }
    }

    let name: String
    let description: String?
    /// Usually a documentation link.
    let source: String?
    /// `stdio` or `http`.
    let transport: String?
    /// `api_key`, `oauth` or `none`.
    let authType: String?
    let requiredEnv: [EnvRequirement]
    let command: String?
    let args: [String]
    let url: String?
    let installURL: String?
    let installRef: String?
    /// Shell commands the host runs in the cloned repository.
    let bootstrap: [String]
    let postInstall: String?
    /// A git clone and bootstrap run first, as a background action that always enables the server.
    let needsInstall: Bool
    let installed: Bool
    let enabled: Bool

    var id: String { name }

    var sourceURL: URL? {
        guard let source, let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text.trimmedNonEmpty else { return nil }
        self.name = name
        description = row["description"].text.trimmedNonEmpty
        source = row["source"].text.trimmedNonEmpty
        transport = row["transport"].text.trimmedNonEmpty
        authType = row["auth_type"].text.trimmedNonEmpty
        var seen = Set<String>()
        requiredEnv = (row["required_env"].list ?? []).compactMap { spec in
            guard let name = spec["name"].text.trimmedNonEmpty, seen.insert(name).inserted else { return nil }
            return EnvRequirement(name: name, prompt: spec["prompt"].text.trimmedNonEmpty,
                                  isRequired: spec["required"].flag ?? true)
        }
        command = row["command"].text.trimmedNonEmpty
        args = (row["args"].list ?? []).compactMap(\.text)
        url = row["url"].text.trimmedNonEmpty
        installURL = row["install_url"].text.trimmedNonEmpty
        installRef = row["install_ref"].text.trimmedNonEmpty
        bootstrap = (row["bootstrap"].list ?? []).compactMap { $0.text.trimmedNonEmpty }
        postInstall = row["post_install"].text.trimmedNonEmpty
        needsInstall = row["needs_install"].flag ?? (installURL != nil)
        installed = row["installed"].flag ?? false
        enabled = row["enabled"].flag ?? false
    }
}

/// `POST /api/mcp/catalog/install`'s answer: installed in the request, or a background
/// action to follow.
enum MCPInstallStart: Hashable {
    case finished
    case background(action: String)

    init?(_ json: BotJSON) {
        guard json["ok"].flag == true else { return nil }
        if json["background"].flag == true {
            guard let action = json["action"].text.trimmedNonEmpty else { return nil }
            self = .background(action: action)
        } else {
            self = .finished
        }
    }
}
