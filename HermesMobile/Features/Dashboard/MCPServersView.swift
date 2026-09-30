import SwiftUI

/// One profile's MCP servers on the Hermes host, with the catalog one row above them. The
/// catalog row never waits on the servers, and the catalog loads only once it is opened.
struct MCPServersView: View {
    let model: MCPServersViewModel
    let catalog: MCPCatalogViewModel

    /// Set once this push has read the list, so coming back from a server doesn't read it again.
    @State private var didOpen = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MCPCatalogView(model: catalog)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Catalog")
                                .font(.body.weight(.semibold))
                            Text("Browse and install approved MCP servers.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "books.vertical")
                    }
                }
            }

            Section("Servers") {
                serverRows
            }
        }
        .navigationTitle(String(localized: "MCP · \(model.profile)"))
        .navigationBarTitleDisplayMode(.inline)
        // Kept rows stay on screen, with the refresh note, while each push reads them again.
        .task {
            guard !didOpen else { return }
            await model.load(force: true)
            didOpen = !Task.isCancelled
        }
        .refreshable { await model.load(force: true) }
        .safeAreaInset(edge: .bottom) { MCPInstallBanner(model: catalog) }
    }

    @ViewBuilder
    private var serverRows: some View {
        if model.servers.isEmpty {
            switch model.listState {
            case .failed(let problem):
                SkillsHubProblemView(title: String(localized: "Could Not Load MCP Servers"), problem: problem) {
                    Task { await model.load(force: true) }
                }
            case .loaded:
                ContentUnavailableView {
                    Label("No MCP Servers", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Install one from the catalog.")
                }
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Loading"))
            }
        } else {
            if let note = model.listState.refreshNote(rowsLoadedAt: model.lastLoadedAt) {
                CatalogRefreshNote(state: note)
            } else if case .failed(let problem) = model.listState {
                Label(problem.message, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Every row opens its server, whatever its source or transport.
            ForEach(model.servers) { server in
                NavigationLink {
                    MCPServerDetailView(model: model, server: server)
                } label: {
                    MCPServerRow(server: server, isPending: model.pendingToggles[server.name] != nil
                                 || model.deleting == server.name)
                }
            }
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let isPending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: server.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                if let endpoint = server.url ?? server.command {
                    Text(verbatim: ([endpoint] + (server.url == nil ? server.args : [])).joined(separator: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                MCPBadgeRow {
                    SkillsHubBadge(text: MCPLabels.transport(server.transport))
                    if let auth = server.auth {
                        SkillsHubBadge(text: MCPLabels.serverAuth(auth), systemImage: "key")
                    }
                    SkillsHubBadge(text: String(localized: server.enabled ? "Enabled" : "Disabled"))
                    if server.isFromPlugin {
                        SkillsHubBadge(text: MCPLabels.plugin(server.plugin), systemImage: "puzzlepiece.extension")
                    }
                }
            }

            Spacer(minLength: 0)

            if isPending {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Badges side by side, stacked instead at accessibility text sizes so none is cut off.
struct MCPBadgeRow<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        layout { content }
    }
}

/// A label over a selectable host value, monospaced for commands, arguments, URLs and names.
struct MCPValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var monospaced = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Display names for the host's MCP vocabulary; unknown values from a newer host show as sent.
enum MCPLabels {
    static func transport(_ value: String?) -> String {
        switch value {
        case "http"?: return "HTTP"
        case "stdio"?: return "stdio"
        case "unknown"?, nil: return String(localized: "Unknown transport")
        case let value?: return value
        }
    }

    static func serverAuth(_ value: String) -> String {
        switch value {
        case "oauth": return "OAuth"
        case "header": return String(localized: "Authorization header")
        default: return value
        }
    }

    /// Nil for `none`, which needs no badge.
    static func catalogAuth(_ value: String?) -> String? {
        switch value {
        case "api_key"?: return String(localized: "API key")
        case "oauth"?: return "OAuth"
        case "none"?, nil: return nil
        case let value?: return value
        }
    }

    static func plugin(_ name: String?) -> String {
        name.map { String(localized: "Plugin: \($0)") } ?? String(localized: "Plugin")
    }

    static func toolFilter(_ filter: MCPToolFilter) -> String {
        switch filter {
        case .all: return String(localized: "All tools")
        case .include(let names) where names.isEmpty: return String(localized: "No tools")
        case .include(let names): return String(localized: "Only \(names.joined(separator: ", "))")
        case .exclude(let names) where names.isEmpty: return String(localized: "All tools")
        case .exclude(let names): return String(localized: "All except \(names.joined(separator: ", "))")
        case .custom: return String(localized: "Custom tool filter")
        }
    }
}

/// The catalog's running, finished or failed install, on every MCP screen, so leaving and
/// coming back keeps it in view.
struct MCPInstallBanner: View {
    let model: MCPCatalogViewModel

    var body: some View {
        if let operation = model.operation {
            DashboardOperationBanner(status: status(operation.phase), title: title(operation),
                                     lines: operation.lines, dismiss: model.dismissInstallResult)
        }
    }

    private func status(_ phase: MCPCatalogViewModel.InstallPhase) -> DashboardOperationBanner.Status {
        switch phase {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        }
    }

    private func title(_ operation: MCPCatalogViewModel.InstallState) -> String {
        switch operation.phase {
        case .running: return String(localized: "Installing “\(operation.name)” on your Hermes host…")
        case .succeeded(let message), .failed(let message): return message
        }
    }
}
