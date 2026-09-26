import SwiftUI

/// The host's curated plugin catalog, searched and filtered by tier on the phone. Every entry
/// opens its review, however sparse, and the plugins the catalog pulled are listed below.
struct PluginCatalogView: View {
    let model: PluginCatalogViewModel

    @State private var query = ""
    @State private var tier = PluginCatalogViewModel.TierFilter.all

    var body: some View {
        content
            .navigationTitle("Catalog")
            .searchable(text: $query, prompt: Text("Search the plugin catalog"))
            .task { await model.load() }
            .safeAreaInset(edge: .bottom) { PluginInstallBanner(model: model) }
    }

    @ViewBuilder
    private var content: some View {
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
                    Text("Your Hermes host’s plugin catalog is empty.")
                }
            case .idle, .loading:
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            }
        } else {
            List {
                Section {
                    Picker("Tier", selection: $tier) {
                        Text("All").tag(PluginCatalogViewModel.TierFilter.all)
                        Text("Official").tag(PluginCatalogViewModel.TierFilter.official)
                        Text("Community").tag(PluginCatalogViewModel.TierFilter.community)
                    }
                    .pickerStyle(.segmented)
                    if case .failed(let problem) = model.state {
                        Label(problem.message, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                entrySection
                if !model.catalog.removed.isEmpty {
                    removedSection
                }
            }
            .refreshable { await model.load(force: true) }
        }
    }

    @ViewBuilder
    private var entrySection: some View {
        let entries = model.matching(query, tier: tier)
        Section {
            if entries.isEmpty {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    Text("No plugins in this tier.")
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
            ForEach(entries) { entry in
                NavigationLink {
                    PluginCatalogDetailView(model: model, entry: entry)
                } label: {
                    PluginCatalogRow(entry: entry)
                }
            }
        }
    }

    private var removedSection: some View {
        Section {
            ForEach(Array(model.catalog.removed.enumerated()), id: \.offset) { _, removal in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: removal.name)
                        .font(.callout.monospaced())
                    if let reason = removal.reason {
                        Text(verbatim: reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = removal.date {
                        Text(verbatim: date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Pulled from the catalog")
        } footer: {
            Text("Hermes won’t install or update these.")
        }
    }
}

private struct PluginCatalogRow: View {
    let entry: PluginCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: entry.displayTitle)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            if entry.title != nil {
                Text(verbatim: entry.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let description = entry.description {
                Text(verbatim: description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            PluginCatalogBadges(entry: entry)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Tier, category, and installed and update state.
struct PluginCatalogBadges: View {
    let entry: PluginCatalogEntry

    var body: some View {
        MCPBadgeRow {
            if let tier = PluginLabels.tier(entry.tier) {
                SkillsHubBadge(text: tier, systemImage: entry.tier == "official" ? "checkmark.seal" : "person.2")
            }
            if let category = entry.category {
                SkillsHubBadge(text: category)
            }
            if entry.installed {
                SkillsHubBadge(text: String(localized: "Installed"), systemImage: "checkmark")
            }
            if entry.updateAvailable {
                SkillsHubBadge(text: String(localized: "Update available"), systemImage: "arrow.down.circle")
            }
        }
    }
}
