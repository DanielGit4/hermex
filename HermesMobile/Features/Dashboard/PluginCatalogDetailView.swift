import SwiftUI

/// One catalog entry, reviewed before anything is installed: who maintains it, the exact
/// repository and commit, where it runs and every capability it registers, all above the
/// Install button. Installing runs third-party code on the host.
struct PluginCatalogDetailView: View {
    let model: PluginCatalogViewModel
    /// The row this opened from; the screen follows the model's copy once the catalog reloads.
    let entry: PluginCatalogEntry

    @State private var isPresentingInstall = false

    private var current: PluginCatalogEntry { model.entry(named: entry.name) ?? entry }
    private var removal: PluginCatalog.Removal? { model.catalog.removal(for: current) }
    private var result: PluginCatalogViewModel.InstallPhase? {
        model.operation?.name == entry.name ? model.operation?.phase : nil
    }

    var body: some View {
        List {
            Section {
                header
            }
            if let removal {
                Section {
                    Label(removal.reason.map { String(localized: "Pulled from the plugin catalog: \($0). Hermes won’t install it.") }
                          ?? String(localized: "Pulled from the plugin catalog. Hermes won’t install it."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            PluginReviewSections(entry: current)
            Section("Compatibility") {
                MCPValueRow(title: "Platforms", value: PluginLabels.platforms(current.platforms), monospaced: false)
                MCPValueRow(title: "Requires Hermes", value: current.requiresHermes ?? String(localized: "Any version"))
                if let category = current.category {
                    MCPValueRow(title: "Category", value: category, monospaced: false)
                }
            }
            if let summary = current.capabilitySummary {
                Section("Summary") {
                    Text(verbatim: summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if let docs = current.docsLink {
                Section("Documentation") {
                    Link(destination: docs) {
                        Text(verbatim: docs.absoluteString)
                            .font(.callout)
                    }
                }
            } else if let docs = current.docsURL {
                Section("Documentation") {
                    Text(verbatim: docs)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let result {
                PluginInstallResultSection(phase: result)
            }
            installSection
        }
        .navigationTitle(current.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { PluginInstallBanner(model: model) }
        .sheet(isPresented: $isPresentingInstall) {
            PluginInstallSheet(model: model, entry: current)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: current.displayTitle)
                .font(.title3.weight(.bold))
            Text(verbatim: current.name)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let description = current.description {
                Text(verbatim: description)
                    .foregroundStyle(.secondary)
            }
            PluginCatalogBadges(entry: current)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var installSection: some View {
        if current.installed {
            Section {
                Label("Installed on your Hermes host", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } footer: {
                if current.updateAvailable {
                    Text("An update is available. Update it from the plugin’s page under Installed.")
                } else {
                    Text("Manage it from the plugin’s page under Installed.")
                }
            }
        } else if removal == nil {
            Section {
                Button {
                    isPresentingInstall = true
                } label: {
                    Text("Review and Install…")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canInstall(current))
            } footer: {
                Text("Installing downloads this commit to your Hermes host and runs its code there.")
            }
        }
    }
}

/// Tier with who stands behind it, maintainer, the exact source and every capability: what
/// the detail shows and the install review repeats.
struct PluginReviewSections: View {
    let entry: PluginCatalogEntry

    var body: some View {
        Section {
            if let tier = PluginLabels.tier(entry.tier) {
                MCPValueRow(title: "Tier", value: tier, monospaced: false)
            }
            if let maintainer = entry.maintainer {
                MCPValueRow(title: "Maintainer", value: maintainer, monospaced: false)
            }
        } header: {
            Text("Maintainer")
        } footer: {
            if let note = PluginLabels.tierNote(entry.tier) {
                Text(note)
                    .foregroundStyle(entry.tier == "community" ? Color.orange : Color.secondary)
            }
        }
        Section("Source") {
            if let repo = entry.repo {
                MCPValueRow(title: "Repository", value: repo)
            }
            if let pin = entry.pin {
                MCPValueRow(title: "Pinned version", value: pin)
            }
            if let sha = entry.sha {
                MCPValueRow(title: "Commit", value: sha)
            }
            if let subdir = entry.subdir {
                MCPValueRow(title: "Folder in repository", value: subdir)
            }
        }
        Section {
            PluginCapabilityRow(title: "Tools", names: entry.capabilities.tools)
            PluginCapabilityRow(title: "Hooks", names: entry.capabilities.hooks)
            PluginCapabilityRow(title: "Middleware", names: entry.capabilities.middleware)
            PluginCapabilityRow(title: "Required environment variables", names: entry.capabilities.requiredEnv)
        } header: {
            Text("Capabilities")
        } footer: {
            Text("What the plugin registers with Hermes. Required environment variables are set on the host.")
        }
    }
}

private struct PluginCapabilityRow: View {
    let title: LocalizedStringKey
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if names.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: names.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The finished install for this entry: what it needs next, or why it was refused.
private struct PluginInstallResultSection: View {
    let phase: PluginCatalogViewModel.InstallPhase

    var body: some View {
        switch phase {
        case .running, .confirming:
            EmptyView()
        case .succeeded(let result):
            Section("Install Result") {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let result {
                    Text(PluginLabels.liveness(result.liveness))
                        .font(.callout)
                    if !result.missingEnv.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Set these on your Hermes host before using the plugin. Hermex can’t enter keys yet.")
                                .font(.callout)
                            Text(verbatim: result.missingEnv.joined(separator: "\n"))
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    PluginNoteList(title: "Warnings", items: result.warnings)
                    PluginNoteList(title: "Python dependencies", items: result.pythonDependencies)
                }
            }
        case .blocked(let block):
            PluginScanBlockSection(block: block)
        case .failed(let message):
            Section("Install Result") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        case .unknown(let message):
            Section("Install Result") {
                Label(message, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The security scan's refusal: the verdict and findings when the host sends them as fields,
/// and its report as sent.
private struct PluginScanBlockSection: View {
    let block: PluginScanBlock

    var body: some View {
        Section {
            Label("Blocked by Hermes’s security scan", systemImage: "xmark.shield.fill")
                .foregroundStyle(.red)
            if let verdict = block.verdict {
                MCPValueRow(title: "Verdict", value: SkillsHubLabels.verdict(verdict), monospaced: false)
            }
            ForEach(Array(block.findings.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: [finding.severity.map(SkillsHubLabels.severity), finding.category ?? finding.patternID]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout.weight(.semibold))
                    if let file = finding.file {
                        Text(verbatim: finding.line.map { "\(file):\($0)" } ?? file)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let description = finding.description {
                        Text(verbatim: description)
                            .font(.caption)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let report = block.report {
                ScrollView(.horizontal) {
                    Text(verbatim: report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Install Result")
        } footer: {
            Text("Nothing was installed. Install only plugins from sources you trust.")
        }
    }
}
