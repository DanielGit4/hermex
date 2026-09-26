import SwiftUI

/// The agent plugins installed on the Hermes host, with the catalog one row above them. The
/// list reads only the host's plugins; the catalog loads beside it for update badges and
/// never holds it back.
struct PluginsView: View {
    let model: PluginsViewModel
    let catalog: PluginCatalogViewModel

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PluginCatalogView(model: catalog)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Catalog")
                                .font(.body.weight(.semibold))
                            Text("Review and install curated plugins.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "books.vertical")
                    }
                }
            }

            Section("Installed") {
                pluginRows
            }
        }
        .navigationTitle("Plugins")
        .task { await model.load() }
        .task { await catalog.load() }
        .refreshable { await model.load(force: true) }
        .safeAreaInset(edge: .bottom) { PluginInstallBanner(model: catalog) }
    }

    @ViewBuilder
    private var pluginRows: some View {
        if let notice = model.removalNotice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if model.plugins.isEmpty {
            switch model.listState {
            case .failed(let problem):
                SkillsHubProblemView(title: String(localized: "Could Not Load Plugins"), problem: problem) {
                    Task { await model.load(force: true) }
                }
            case .loaded:
                ContentUnavailableView {
                    Label("No Plugins", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Install one from the catalog.")
                }
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Loading"))
            }
        } else {
            if case .failed(let problem) = model.listState {
                Label(problem.message, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Every row opens its plugin, whatever its source, status or missing fields.
            ForEach(model.plugins) { plugin in
                NavigationLink {
                    PluginDetailView(model: model, catalog: catalog, plugin: plugin)
                } label: {
                    PluginRow(plugin: plugin,
                              updateAvailable: catalog.catalog.entry(installedAs: plugin.name)?.updateAvailable == true,
                              isBusy: model.activity[plugin.name] != nil)
                }
            }
        }
    }
}

private struct PluginRow: View {
    let plugin: AgentPlugin
    let updateAvailable: Bool
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: plugin.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                if let description = plugin.description {
                    Text(verbatim: description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                MCPBadgeRow {
                    PluginBadges(plugin: plugin)
                    if updateAvailable {
                        SkillsHubBadge(text: String(localized: "Update available"), systemImage: "arrow.down.circle")
                    }
                }
                if plugin.authRequired || plugin.removedReason != nil {
                    MCPBadgeRow {
                        PluginWarningBadges(plugin: plugin)
                    }
                }
            }

            Spacer(minLength: 0)

            if isBusy {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Version, source and status.
struct PluginBadges: View {
    let plugin: AgentPlugin

    var body: some View {
        if let version = plugin.version {
            SkillsHubBadge(text: version)
        }
        SkillsHubBadge(text: PluginLabels.source(plugin.source))
        SkillsHubBadge(text: PluginLabels.status(plugin.runtimeStatus))
    }
}

/// A plugin that needs a sign-in on the host, or that the catalog pulled.
struct PluginWarningBadges: View {
    let plugin: AgentPlugin

    var body: some View {
        if plugin.authRequired {
            SkillsHubBadge(text: String(localized: "Needs sign-in on host"), systemImage: "person.badge.key", tint: .orange)
        }
        if plugin.removedReason != nil {
            SkillsHubBadge(text: String(localized: "Pulled from catalog"), systemImage: "exclamationmark.triangle.fill", tint: .red)
        }
    }
}

/// The catalog's running or finished install, on every plugin screen, so leaving and coming
/// back keeps it in view. The catalog entry's page shows the full result.
struct PluginInstallBanner: View {
    let model: PluginCatalogViewModel

    var body: some View {
        if let operation = model.operation {
            DashboardOperationBanner(status: status(operation.phase), title: title(operation),
                                     lines: [], dismiss: model.dismissInstallResult)
        }
    }

    private func status(_ phase: PluginCatalogViewModel.InstallPhase) -> DashboardOperationBanner.Status {
        switch phase {
        case .running, .confirming: return .running
        case .succeeded: return .succeeded
        case .failed, .blocked: return .failed
        case .unknown: return .uncertain
        }
    }

    private func title(_ operation: PluginCatalogViewModel.InstallState) -> String {
        switch operation.phase {
        case .running: return String(localized: "Installing “\(operation.title)” on your Hermes host…")
        case .confirming: return String(localized: "Hermes may still be working on this. Checking what it installed…")
        case .succeeded: return String(localized: "Installed “\(operation.title)” on your Hermes host.")
        case .blocked: return String(localized: "Hermes’s security scan blocked “\(operation.title)”.")
        case .failed(let message), .unknown(let message): return message
        }
    }
}
