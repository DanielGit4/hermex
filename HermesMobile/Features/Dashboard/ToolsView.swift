import SwiftUI

/// The profiles on the Hermes host, each with how many of its toolsets are on. A host with one
/// profile opens straight to that profile's page.
struct ToolsDestination: View {
    let models: DashboardModelStore.Bundle

    private var model: ToolsProfilesViewModel { models.tools }

    var body: some View {
        content
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if let sole = model.soleProfile {
            ProfileToolsView(model: sole, profileModels: models.profile(sole.profile))
        } else {
            List {
                if model.profiles.isEmpty {
                    placeholder
                } else {
                    if let note = model.listState.refreshNote(rowsLoadedAt: model.lastLoadedAt) {
                        CatalogRefreshNote(state: note)
                    }
                    ForEach(model.profiles) { profile in
                        NavigationLink {
                            ProfileToolsView(model: profile.tools, profileModels: models.profile(profile.name))
                        } label: {
                            ToolsProfileRow(profile: profile)
                        }
                    }
                }
            }
            .navigationTitle("Profiles")
            .refreshable { await model.load(force: true) }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.listState {
        case .failed(let problem):
            SkillsHubProblemView(title: String(localized: "Could Not Load Profiles"), problem: problem) {
                Task { await model.load(force: true) }
            }
        case .loaded:
            ContentUnavailableView("No tools", systemImage: "wrench.and.screwdriver")
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Loading"))
        }
    }
}

private struct ToolsProfileRow: View {
    let profile: ToolsProfilesViewModel.ProfileSummary

    var body: some View {
        // Label and count side by side, stacked at accessibility text sizes.
        LabeledContent {
            if let enabled = profile.enabledCount, let total = profile.totalCount {
                Text("\(enabled) of \(total) tools on")
            }
        } label: {
            Text(verbatim: profile.name)
                .font(.body.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}

/// One profile's page: its skills and MCP servers one tap away, then its toolsets, each
/// switched on or off on the host. Toolsets the host limits to another platform get their
/// own section. Only the toolsets load here; skills and MCP servers load when opened.
struct ProfileToolsView: View {
    let model: ProfileToolsViewModel
    let profileModels: DashboardModelStore.ProfileModels

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SkillsHubView(model: profileModels.skillsHub)
                } label: {
                    Label("Skills", systemImage: "hammer")
                }
                NavigationLink {
                    MCPServersView(model: profileModels.mcpServers, catalog: profileModels.mcpCatalog)
                } label: {
                    Label("MCP servers", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            content
        }
        .navigationTitle(Text(verbatim: model.profile))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load(force: true) }
        .onDisappear { model.clearNotices() }
    }

    @ViewBuilder
    private var content: some View {
        if model.toolsets.isEmpty {
            switch model.listState {
            case .failed(let problem):
                SkillsHubProblemView(title: String(localized: "Could Not Load Tools"), problem: problem) {
                    Task { await model.load(force: true) }
                }
            case .loaded:
                ContentUnavailableView("No tools", systemImage: "wrench.and.screwdriver")
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Loading"))
            }
        } else {
            let sections = model.sections
            ForEach(sections) { section in
                Section {
                    if section.id == sections.first?.id,
                       let note = model.listState.refreshNote(rowsLoadedAt: model.lastLoadedAt) {
                        CatalogRefreshNote(state: note)
                    }
                    ForEach(section.toolsets) { toolset in
                        ToolsetRow(model: model, toolset: toolset)
                    }
                } header: {
                    if let title = section.title {
                        Text(verbatim: title)
                    }
                } footer: {
                    if section.id == sections.last?.id {
                        Text("Applies to new messages in this profile’s chats.")
                    }
                }
            }
        }
    }
}

private struct ToolsetRow: View {
    let model: ProfileToolsViewModel
    let toolset: DashboardToolset

    var body: some View {
        let isPending = model.pendingToggles[toolset.name] != nil
        let canTurnOff = model.canTurnOff(toolset.name)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { toolset.enabled }, set: { enabled in
                Task { await model.setEnabled(toolset.name, to: enabled) }
            })) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ToolsetLabel(toolset: toolset)
                    if isPending {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isPending || !canTurnOff)

            if !canTurnOff {
                ToolsetNote(text: ProfileToolsViewModel.guardMessage, systemImage: "info.circle")
            }
            if let problem = model.toggleProblems[toolset.name] {
                ToolsetNote(text: problem, systemImage: "exclamationmark.triangle")
            }
            if model.installNotice == toolset.name {
                ToolsetNote(text: String(localized: "Installing on your Mac…"), systemImage: "arrow.down.circle")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ToolsetLabel: View {
    let toolset: DashboardToolset

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: toolset.label)
            if let description = toolset.description {
                Text(verbatim: description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !toolset.tools.isEmpty || !toolset.configured {
                MCPBadgeRow {
                    if !toolset.tools.isEmpty {
                        Text("\(toolset.tools.count) tools")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !toolset.configured {
                        SkillsHubBadge(text: String(localized: "Needs setup on your Mac"),
                                       systemImage: "wrench.adjustable", tint: .orange)
                    }
                }
            }
        }
    }
}

private struct ToolsetNote: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
