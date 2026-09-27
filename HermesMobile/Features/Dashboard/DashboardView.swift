import SwiftUI

/// The Hermes host's dashboard, reached over the saved Bot connection for this server. The
/// Skills Hub, MCP and Plugins are live; the other sections are listed so the destination's
/// shape is clear and stay inert until they are built.
struct DashboardView: View {
    let server: URL

    /// Kept by `DashboardModelStore` across visits and sharing one signed-in client, so
    /// coming back shows the previous lists and keeps a running install on screen.
    @State private var models: DashboardModelStore.Bundle?
    @State private var didLoadConnection = false

    var body: some View {
        content
            .navigationTitle("Dashboard")
            .task {
                guard !didLoadConnection else { return }
                if let connection = try? BotConnectionStore().load(server: server) {
                    let bundle = DashboardModelStore.shared.bundle(server: server, connection: connection)
                    // Each visit refreshes the three lists at once, so a section opens with rows.
                    bundle.refreshLists()
                    models = bundle
                }
                didLoadConnection = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if let models {
            let skillsHub = models.skillsHub, mcpServers = models.mcpServers, mcpCatalog = models.mcpCatalog
            let plugins = models.plugins, pluginCatalog = models.pluginCatalog
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
