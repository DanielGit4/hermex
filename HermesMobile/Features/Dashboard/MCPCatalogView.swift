import SwiftUI

/// The host's approved MCP catalog, searched on the phone. Every entry opens its review,
/// however sparse, and the manifests the host skipped are listed below.
struct MCPCatalogView: View {
    let model: MCPCatalogViewModel

    @State private var query = ""

    var body: some View {
        content
            .navigationTitle("Catalog")
            .searchable(text: $query, prompt: Text("Search the MCP catalog"))
            .task { await model.load() }
            .safeAreaInset(edge: .bottom) { MCPInstallBanner(model: model) }
    }

    @ViewBuilder
    private var content: some View {
        let entries = model.matching(query)
        if model.entries.isEmpty {
            switch model.state {
            case .failed(let problem):
                SkillsHubProblemView(title: String(localized: "Could Not Load the Catalog"), problem: problem) {
                    Task { await model.load(force: true) }
                }
            case .loaded:
                ContentUnavailableView {
                    Label("No Catalog Entries", systemImage: "books.vertical")
                } description: {
                    Text("Your Hermes host’s MCP catalog is empty.")
                }
            case .idle, .loading:
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            }
        } else if entries.isEmpty {
            ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            List {
                if case .failed(let problem) = model.state {
                    Label(problem.message, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(entries) { entry in
                        NavigationLink {
                            MCPCatalogDetailView(model: model, entry: entry)
                        } label: {
                            MCPCatalogRow(entry: entry)
                        }
                    }
                } footer: {
                    if !model.diagnostics.isEmpty {
                        diagnosticsFooter
                    }
                }
            }
            .refreshable { await model.load(force: true) }
        }
    }

    private var diagnosticsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hermes skipped these catalog entries:")
            ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(verbatim: [diagnostic.name, diagnostic.message].compactMap { $0 }.joined(separator: ": "))
                    .font(.caption.monospaced())
            }
        }
    }
}

private struct MCPCatalogRow: View {
    let entry: MCPCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: entry.name)
                .font(.body.weight(.semibold))
                .lineLimit(2)

            if let description = entry.description {
                Text(verbatim: description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            MCPCatalogBadges(entry: entry)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Transport, auth, a repository install, and installed and enabled state.
struct MCPCatalogBadges: View {
    let entry: MCPCatalogEntry

    var body: some View {
        MCPBadgeRow {
            SkillsHubBadge(text: MCPLabels.transport(entry.transport))
            if let auth = MCPLabels.catalogAuth(entry.authType) {
                SkillsHubBadge(text: auth, systemImage: "key")
            }
            if entry.needsInstall {
                SkillsHubBadge(text: String(localized: "Repository"), systemImage: "arrow.down.circle")
            }
            if entry.installed {
                SkillsHubBadge(text: String(localized: "Installed"), systemImage: "checkmark")
                SkillsHubBadge(text: String(localized: entry.enabled ? "Enabled" : "Disabled"))
            }
        }
    }
}
