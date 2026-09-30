import Foundation

/// One `GET /api/tools/toolsets` row: a toolset one profile can switch on or off. The host
/// strips the label's emoji; `platform` is `cli` unless the host restricts the toolset to
/// another platform, such as `discord`.
struct DashboardToolset: Identifiable, Equatable {
    /// The host's key, sent back as sent when toggling.
    let name: String
    let label: String
    let description: String?
    let platform: String
    let platformLabel: String?
    var enabled: Bool
    /// False when the host lacks keys or setup the toolset needs. Unknown counts as set up.
    let configured: Bool
    let tools: [String]

    var id: String { name }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text.trimmedNonEmpty else { return nil }
        self.name = name
        label = row["label"].text.trimmedNonEmpty ?? name
        description = row["description"].text.trimmedNonEmpty
        platform = row["platform"].text.trimmedNonEmpty ?? "cli"
        platformLabel = row["platform_label"].text.trimmedNonEmpty
        enabled = row["enabled"].flag ?? false
        configured = row["configured"].flag ?? true
        tools = (row["tools"].list ?? []).compactMap(\.text)
    }
}

/// `PUT /api/tools/toolsets/{name}`'s answer: the value the host saved, and the setup it
/// started installing on the host, if enabling needed one.
struct ToolsetToggleResult: Equatable {
    let enabled: Bool
    let postSetupStarted: String?

    init?(_ json: BotJSON) {
        guard let enabled = json["enabled"].flag else { return nil }
        self.enabled = enabled
        postSetupStarted = json["post_setup_started"].text.trimmedNonEmpty
    }
}
