import SwiftUI

/// The Hermes host's dashboard, reached over the saved Bot connection for this server. The
/// Skills Hub, MCP and Plugins are live; the other sections are listed so the destination's
/// shape is clear and stay inert until they are built.
struct DashboardView: View {
    let server: URL

    /// Built once per visit and sharing one signed-in client, so leaving a section and
    /// coming back keeps a running install on screen.
    @State private var skillsHub: SkillsHubViewModel?
    @State private var mcpServers: MCPServersViewModel?
    @State private var mcpCatalog: MCPCatalogViewModel?
    @State private var plugins: PluginsViewModel?
    @State private var pluginCatalog: PluginCatalogViewModel?
    @State private var didLoadConnection = false

    var body: some View {
        content
            .navigationTitle("Dashboard")
            .task {
                guard !didLoadConnection else { return }
                if let connection = try? BotConnectionStore().load(server: server) {
                    let client = DashboardClient(connection: connection)
                    let servers = MCPServersViewModel(client: client)
                    let installed = PluginsViewModel(client: client)
                    skillsHub = SkillsHubViewModel(client: client)
                    mcpServers = servers
                    mcpCatalog = MCPCatalogViewModel(client: client, servers: servers)
                    plugins = installed
                    pluginCatalog = PluginCatalogViewModel(client: client, plugins: installed)
                }
                didLoadConnection = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if let skillsHub, let mcpServers, let mcpCatalog, let plugins, let pluginCatalog {
            List {
                Section {
                    NavigationLink {
                        SkillsHubView(model: skillsHub)
                    } label: {
                        DashboardSectionLabel(title: "Skills Hub", systemImage: "hammer",
                                              subtitle: "Search, install and update skills on your Hermes host.")
                    }
                    NavigationLink {
                        MCPServersView(model: mcpServers, catalog: mcpCatalog)
                    } label: {
                        DashboardSectionLabel(title: "MCP", systemImage: "point.3.connected.trianglepath.dotted",
                                              subtitle: "Test, enable and remove MCP servers, or install from the catalog.")
                    }
                    NavigationLink {
                        PluginsView(model: plugins, catalog: pluginCatalog)
                    } label: {
                        DashboardSectionLabel(title: "Plugins", systemImage: "puzzlepiece.extension",
                                              subtitle: "Enable, update and remove plugins, or install from the catalog.")
                    }
                }

                Section("Coming Soon") {
                    ForEach(UpcomingSection.allCases) { section in
                        UpcomingSectionRow(section: section)
                    }
                }
            }
        } else if didLoadConnection {
            ContentUnavailableView {
                Label("No Hermes Connection", systemImage: "link")
            } description: {
                Text("Connect your Hermes host in Bots to use the Dashboard.")
            }
        } else {
            // A real view, so the `.task` that loads the connection has something to run on.
            ProgressView()
        }
    }
}

private struct DashboardSectionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let subtitle: LocalizedStringKey

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// Dashboard sections that are planned but not built. Their rows are plain text, never
/// buttons, so nothing here navigates.
private enum UpcomingSection: CaseIterable, Identifiable {
    case config, keys, logs, gateway

    var id: Self { self }

    var title: String {
        switch self {
        case .config: return String(localized: "Config")
        case .keys: return String(localized: "Keys")
        case .logs: return String(localized: "Logs")
        case .gateway: return String(localized: "Gateway")
        }
    }

    var systemImage: String {
        switch self {
        case .config: return "slider.horizontal.3"
        case .keys: return "key"
        case .logs: return "doc.plaintext"
        case .gateway: return "antenna.radiowaves.left.and.right"
        }
    }
}

private struct UpcomingSectionRow: View {
    let section: UpcomingSection

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.systemImage)
            Spacer(minLength: 8)
            Text("Coming Soon")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
