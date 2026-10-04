import SwiftUI

/// One profile's installed skills while the search field is empty, Skills Hub results while
/// it is not.
struct SkillsHubView: View {
    let model: SkillsHubViewModel

    @State private var query = ""
    @State private var skillPendingUninstall: DashboardSkill?
    @State private var isConfirmingUpdate = false

    var body: some View {
        content
            .navigationTitle(String(localized: "Skills · \(model.profile)"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search the Skills Hub"))
            .task { await model.loadInstalled() }
            .task(id: query) { await model.search(query) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isConfirmingUpdate = true
                    } label: {
                        Label("Update Hub Skills", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!model.hasHubSkills || model.isWorking)
                }
            }
            .safeAreaInset(edge: .bottom) { SkillsHubOperationBanner(model: model) }
            .confirmationDialog(
                "Update hub skills?",
                isPresented: $isConfirmingUpdate,
                titleVisibility: .visible
            ) {
                Button("Update Skills") { Task { await model.update() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hermes downloads newer versions of the skills installed from the hub, scans each one before replacing it, and keeps skills you edited on the host.")
            }
            .confirmationDialog(
                uninstallTitle,
                isPresented: isConfirmingUninstall,
                titleVisibility: .visible,
                presenting: skillPendingUninstall
            ) { skill in
                Button("Uninstall", role: .destructive) { Task { await model.uninstall(skill.name) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Deletes the skill’s folder from the “\(model.profile)” profile on your Hermes host, including any edits made there. New sessions won’t load it. You can install it again from the Skills Hub.")
            }
            .alert("Couldn’t Confirm It’s You", isPresented: authenticationProblemIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.authenticationProblem ?? "")
            }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            installedContent
        } else {
            searchContent
        }
    }

    // MARK: - Installed

    @ViewBuilder
    private var installedContent: some View {
        if model.installedSections.isEmpty {
            switch model.installedState {
            case .failed(let problem):
                SkillsHubProblemView(title: String(localized: "Could Not Load Skills"), problem: problem) {
                    Task { await model.loadInstalled() }
                }
            case .loaded:
                ContentUnavailableView {
                    Label("No Skills Installed", systemImage: "hammer")
                } description: {
                    Text("Search the Skills Hub to install one.")
                }
            case .idle, .loading:
                ProgressView("Loading skills...")
            }
        } else {
            List {
                if let note = model.installedState.refreshNote(rowsLoadedAt: model.installedLoadedAt) {
                    CatalogRefreshNote(state: note)
                } else if case .failed(let problem) = model.installedState {
                    Label(problem.message, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.installedSections) { section in
                    Section(SkillsHubLabels.provenance(section.provenance)) {
                        ForEach(section.skills) { skill in
                            installedRow(skill)
                        }
                    }
                }
            }
            .refreshable { await model.loadInstalled() }
        }
    }

    /// Hub skills are the only ones `hermes skills uninstall` removes, so only their rows offer it.
    @ViewBuilder
    private func installedRow(_ skill: DashboardSkill) -> some View {
        let lock = model.hubLockByName[skill.name]
        let row = InstalledSkillRow(skill: skill, lock: lock,
                                    isWorking: model.isRunning(.uninstall(name: skill.name)))
        let link = NavigationLink {
            InstalledSkillDetailView(model: model, skill: skill, lock: lock)
        } label: {
            row
        }
        if skill.isFromHub {
            link
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Uninstall", role: .destructive) { skillPendingUninstall = skill }
                        .disabled(model.isWorking)
                }
                .contextMenu {
                    Button("Uninstall", systemImage: "trash", role: .destructive) { skillPendingUninstall = skill }
                        .disabled(model.isWorking)
                }
        } else {
            link
        }
    }

    private var uninstallTitle: String {
        String(localized: "Uninstall “\(skillPendingUninstall?.name ?? "")”?")
    }

    private var isConfirmingUninstall: Binding<Bool> {
        Binding(get: { skillPendingUninstall != nil }, set: { if !$0 { skillPendingUninstall = nil } })
    }

    private var authenticationProblemIsPresented: Binding<Bool> {
        Binding(get: { model.authenticationProblem != nil }, set: { if !$0 { model.authenticationProblem = nil } })
    }

    // MARK: - Search

    @ViewBuilder
    private var searchContent: some View {
        if model.results.isEmpty {
            switch model.searchState {
            case .failed(let problem):
                SkillsHubProblemView(title: String(localized: "Could Not Load Skills"), problem: problem) {
                    Task { await model.search(query, force: true) }
                }
            case .loaded:
                ContentUnavailableView.search(text: trimmedQuery)
            case .idle, .loading:
                ProgressView("Searching…")
            }
        } else {
            List {
                Section {
                    ForEach(model.results) { skill in
                        NavigationLink {
                            SkillsHubDetailView(model: model, skill: skill)
                        } label: {
                            HubSkillRow(skill: skill, isInstalled: model.isInstalled(skill.identifier))
                        }
                    }
                } footer: {
                    if !model.timedOutSources.isEmpty {
                        Text("Some sources didn’t answer in time: \(model.timedOutSources.joined(separator: ", "))")
                    }
                }
            }
            .overlay(alignment: .top) {
                if model.searchState == .loading {
                    ProgressView()
                        .padding(8)
                }
            }
            .refreshable { await model.search(query, force: true) }
        }
    }
}

private struct InstalledSkillRow: View {
    let skill: DashboardSkill
    let lock: HubLockEntry?
    let isWorking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                if let description = skill.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if lock?.trustLevel != nil || !skill.enabled {
                    HStack(spacing: 6) {
                        if let trust = lock?.trustLevel {
                            SkillsHubBadge(text: SkillsHubLabels.trust(trust))
                        }
                        if let verdict = lock?.scanVerdict {
                            SkillsHubBadge(text: SkillsHubLabels.verdict(verdict))
                        }
                        if !skill.enabled {
                            SkillsHubBadge(text: String(localized: "Disabled"))
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if isWorking {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct HubSkillRow: View {
    let skill: HubSkill
    let isInstalled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(skill.name)
                .font(.body.weight(.semibold))
                .lineLimit(2)

            if let description = skill.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                if let source = skill.source {
                    SkillsHubBadge(text: source)
                }
                if let trust = skill.trustLevel {
                    SkillsHubBadge(text: SkillsHubLabels.trust(trust))
                }
                if isInstalled {
                    SkillsHubBadge(text: String(localized: "Installed"), systemImage: "checkmark")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct SkillsHubBadge: View {
    let text: String
    var systemImage: String?
    /// A warning's color; plain badges stay secondary.
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(verbatim: text)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .background(tint.map { $0.opacity(0.15) } ?? Color(.tertiarySystemFill), in: Capsule())
    }
}

struct SkillsHubProblemView: View {
    let title: String
    let problem: DashboardProblem
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
        } description: {
            Text(problem.message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

/// The running, finished or failed install, uninstall or update, pinned to the bottom of
/// the Skills Hub screens. Success appears only once the host has confirmed it.
struct SkillsHubOperationBanner: View {
    let model: SkillsHubViewModel

    var body: some View {
        if let operation = model.operation {
            DashboardOperationBanner(status: status(for: operation.phase), title: title(for: operation),
                                     lines: operation.lines, dismiss: model.dismissOperationResult)
        }
    }

    private func status(for phase: SkillsHubViewModel.OperationPhase) -> DashboardOperationBanner.Status {
        switch phase {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        }
    }

    private func title(for state: SkillsHubViewModel.OperationState) -> String {
        switch state.phase {
        case .succeeded(let message), .failed(let message):
            return message
        case .running:
            switch state.operation {
            case .install(_, let name): return String(localized: "Installing “\(name)” on your Hermes host…")
            case .uninstall(let name): return String(localized: "Removing “\(name)” from your Hermes host…")
            case .update: return String(localized: "Updating hub skills on your Hermes host…")
            }
        }
    }
}

/// A dashboard action's progress, pinned to the bottom of the screens that start it: a
/// spinner and the host's latest log line while it runs, then the outcome, dismissible.
struct DashboardOperationBanner: View {
    /// `uncertain`: the host may still be working and the outcome isn't known.
    enum Status { case running, succeeded, failed, uncertain }

    let status: Status
    let title: String
    let lines: [String]
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let lastLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text(verbatim: lastLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if status != .running {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
                .padding(.vertical, -12)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .running:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .uncertain:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}

/// Display names for the host's vocabulary; unknown values from a newer host show as sent.
enum SkillsHubLabels {
    static func provenance(_ value: String) -> String {
        switch value {
        case "hub": return String(localized: "From the Skills Hub")
        case "bundled": return String(localized: "Bundled with Hermes")
        case "agent": return String(localized: "Created on the Host")
        case "": return String(localized: "Other")
        default: return value
        }
    }

    static func trust(_ value: String) -> String {
        switch value {
        case "builtin": return String(localized: "Built-in")
        case "trusted": return String(localized: "Trusted")
        case "community": return String(localized: "Community")
        case "agent-created": return String(localized: "Agent-created")
        default: return value
        }
    }

    static func verdict(_ value: String) -> String {
        switch value {
        case "safe": return String(localized: "Scan: Safe")
        case "caution": return String(localized: "Scan: Caution")
        case "dangerous": return String(localized: "Scan: Dangerous")
        default: return value
        }
    }

    static func severity(_ value: String) -> String {
        switch value {
        case "critical": return String(localized: "Critical")
        case "high": return String(localized: "High")
        case "medium": return String(localized: "Medium")
        case "low": return String(localized: "Low")
        default: return value
        }
    }
}
