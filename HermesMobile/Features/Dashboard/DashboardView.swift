import SwiftUI

/// The Hermes host's dashboard, reached over the saved Bot connection for this server. The
/// Skills Hub is live; the other sections are listed so the destination's shape is clear
/// and stay inert until they are built.
struct DashboardView: View {
    let server: URL

    /// Built once per visit, so leaving the Skills Hub and coming back keeps a running
    /// install on screen.
    @State private var skillsHub: SkillsHubViewModel?
    @State private var didLoadConnection = false

    var body: some View {
        content
            .navigationTitle("Dashboard")
            .task {
                guard !didLoadConnection else { return }
                if let connection = try? BotConnectionStore().load(server: server) {
                    skillsHub = SkillsHubViewModel(client: DashboardClient(connection: connection))
                }
                didLoadConnection = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if let skillsHub {
            List {
                Section {
                    NavigationLink {
                        SkillsHubView(model: skillsHub)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skills Hub")
                                    .font(.body.weight(.semibold))
                                Text("Search, install and update skills on your Hermes host.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "hammer")
                        }
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

/// Dashboard sections that are planned but not built. Their rows are plain text, never
/// buttons, so nothing here navigates.
private enum UpcomingSection: CaseIterable, Identifiable {
    case mcp, plugins, config, keys, logs, gateway

    var id: Self { self }

    var title: String {
        switch self {
        case .mcp: return String(localized: "MCP")
        case .plugins: return String(localized: "Plugins")
        case .config: return String(localized: "Config")
        case .keys: return String(localized: "Keys")
        case .logs: return String(localized: "Logs")
        case .gateway: return String(localized: "Gateway")
        }
    }

    var systemImage: String {
        switch self {
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .plugins: return "puzzlepiece.extension"
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
