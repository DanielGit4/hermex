import SwiftUI
import UIKit

/// One agent plugin on the Hermes host. It renders from the hub row at once; the catalog
/// provenance, the toggle, update and remove each load and fail on their own.
struct PluginDetailView: View {
    let model: PluginsViewModel
    let catalog: PluginCatalogViewModel
    /// The row this opened from; the screen follows the model's copy once it changes.
    let plugin: AgentPlugin

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemove = false
    /// The consent on screen. Kept apart from the model's phase so dismissing the alert
    /// never races the confirmed request that replaces that phase.
    @State private var presentedConsent: PluginConsent?

    private var current: AgentPlugin { model.plugin(named: plugin.name) ?? plugin }
    private var catalogEntry: PluginCatalogEntry? { catalog.catalog.entry(installedAs: plugin.name) }
    private var isBusy: Bool { model.activity[plugin.name] != nil }

    private var consent: PluginConsent? {
        if case .needsConsent(let consent)? = model.updates[plugin.name] { return consent }
        return nil
    }

    var body: some View {
        List {
            Section {
                header
            }
            if let reason = current.removedReason {
                Section {
                    Label(String(localized: "Pulled from the plugin catalog: \(reason). Hermes won’t load or update it; remove it, or keep it knowingly from the host."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            statusSection
            if current.authRequired {
                PluginAuthSection(command: current.authCommand)
            }
            detailsSection
            provenanceSection
            if PluginsViewModel.canUpdate(current, catalogEntry: catalogEntry) || model.updates[plugin.name] != nil {
                PluginUpdateSection(model: model, catalog: catalog, name: plugin.name)
            }
            removeSection
        }
        .navigationTitle(plugin.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await catalog.load() }
        .safeAreaInset(edge: .bottom) { PluginInstallBanner(model: catalog) }
        .confirmationDialog(
            String(localized: "Remove “\(plugin.name)”?"),
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    if await model.remove(plugin.name) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes “\(plugin.name)” from your Hermes host’s plugins folder and forgets whether it was enabled and what it was allowed to do. New sessions won’t load it. Data it saved outside its folder stays.")
        }
        .alert("Couldn’t Confirm It’s You", isPresented: authenticationProblemIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.authenticationProblem ?? "")
        }
        .onChange(of: consent, initial: true) { _, consent in presentedConsent = consent }
        .alert("This update adds new capabilities", isPresented: consentIsPresented, presenting: presentedConsent) { _ in
            Button("Update anyway") {
                Task { await model.update(plugin.name, catalog: catalog, acceptingCapabilities: true) }
            }
            Button("Cancel", role: .cancel) { model.cancelConsent(plugin.name) }
        } message: { consent in
            Text(verbatim: (consent.deltaLines + [consent.shortSHA.map { "→ \($0)" }].compactMap { $0 })
                .joined(separator: "\n"))
        }
    }

    private var authenticationProblemIsPresented: Binding<Bool> {
        Binding(get: { model.authenticationProblem != nil }, set: { if !$0 { model.authenticationProblem = nil } })
    }

    private var consentIsPresented: Binding<Bool> {
        Binding(get: { presentedConsent != nil }, set: { if !$0 { presentedConsent = nil } })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: current.name)
                .font(.title3.weight(.bold))
                .textSelection(.enabled)
            if let description = current.description {
                Text(verbatim: description)
                    .foregroundStyle(.secondary)
            }
            MCPBadgeRow {
                PluginBadges(plugin: current)
            }
            if current.authRequired || current.removedReason != nil {
                MCPBadgeRow {
                    PluginWarningBadges(plugin: current)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                HStack(spacing: 8) {
                    Text("Enabled")
                    if model.pendingToggle(plugin.name) != nil {
                        ProgressView()
                    }
                }
            }
            .disabled(isBusy)
            if current.name == HermexPushPlugin.name {
                Label("Hermex uses this plugin for push notifications. Disabling or removing it stops them.",
                      systemImage: "bell.badge")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = model.toggleProblems[plugin.name] {
                    Text(problem)
                        .foregroundStyle(.red)
                }
                if let outcome = model.toggleOutcomes[plugin.name] {
                    Text(Self.note(outcome))
                }
                Text("Changes apply to new sessions. Running sessions keep a disabled plugin until Hermes restarts.")
            }
        }
    }

    /// Shows the value asked for while the host saves it; the host's status otherwise.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.pendingToggle(plugin.name) ?? current.isEnabled },
                set: { enabled in Task { await model.setEnabled(plugin.name, to: enabled) } })
    }

    private static func note(_ outcome: PluginsViewModel.ToggleOutcome) -> String {
        switch outcome {
        case .unchanged(true): return String(localized: "It was already enabled.")
        case .unchanged(false): return String(localized: "It was already disabled.")
        case .enabled(let liveness): return PluginLabels.liveness(liveness)
        case .disabled: return String(localized: "Disabled. It takes effect after Hermes restarts; running sessions keep the plugin until then.")
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section("Details") {
            MCPValueRow(title: "Source", value: PluginLabels.source(current.source), monospaced: false)
            if let version = current.version {
                MCPValueRow(title: "Version", value: version)
            }
            MCPValueRow(title: "Status", value: PluginLabels.status(current.runtimeStatus), monospaced: false)
            if let path = current.path {
                Text(verbatim: path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// The catalog loads on its own: its spinner or failure never holds back the rest.
    @ViewBuilder
    private var provenanceSection: some View {
        switch catalog.state {
        case .loaded:
            if let entry = catalogEntry {
                PluginProvenanceSection(entry: entry)
            } else {
                Section("Plugin Catalog") {
                    Text("Not from the plugin catalog.")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let problem):
            Section("Plugin Catalog") {
                Label(problem.message, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await catalog.load(force: true) } }
            }
        case .idle, .loading:
            Section("Plugin Catalog") {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking the plugin catalog…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Remove

    @ViewBuilder
    private var removeSection: some View {
        if current.canRemove {
            Section {
                Button(role: .destructive) {
                    isConfirmingRemove = true
                } label: {
                    HStack {
                        Text("Remove")
                        Spacer(minLength: 8)
                        if model.activity[plugin.name] == .removing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isBusy)
            } footer: {
                if let problem = model.removeProblems[plugin.name] {
                    Text(problem)
                }
            }
        } else {
            Section {
                if current.isBundled {
                    Text("Bundled with Hermes, so it can’t be removed. You can disable it.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("This plugin isn’t in your Hermes plugins folder, so Hermex can’t remove it.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The host-side command that signs a plugin in, to copy into a terminal on the host.
private struct PluginAuthSection: View {
    let command: String?

    var body: some View {
        Section {
            if let command {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        UIPasteboard.general.string = command
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Copy Command"))
                }
            }
        } header: {
            Text("Needs sign-in on host")
        } footer: {
            if command != nil {
                Text("Run this in a terminal on your Hermes host. Hermex can’t sign plugins in from this iPhone.")
            } else {
                Text("Sign it in on your Hermes host. Hermes didn’t say which command to run.")
            }
        }
    }
}

/// Where a catalog plugin came from, and whether the catalog has a newer commit.
private struct PluginProvenanceSection: View {
    let entry: PluginCatalogEntry

    var body: some View {
        Section {
            if let tier = PluginLabels.tier(entry.tier) {
                MCPValueRow(title: "Tier", value: tier, monospaced: false)
            }
            if let maintainer = entry.maintainer {
                MCPValueRow(title: "Maintainer", value: maintainer, monospaced: false)
            }
            if let pin = entry.pin {
                MCPValueRow(title: "Catalog pin", value: pin)
            }
            if let installed = entry.installedSHA {
                MCPValueRow(title: "Installed commit", value: String(installed.prefix(7)))
            }
            LabeledContent("Update available") {
                Text(entry.updateAvailable ? String(localized: "Yes") : String(localized: "No"))
            }
        } header: {
            Text("Plugin Catalog")
        } footer: {
            if let note = PluginLabels.tierNote(entry.tier) {
                Text(note)
            }
        }
    }
}

/// Update on the host, with the consent a widening re-pin needs and every outcome, including
/// one only a later refresh can tell.
private struct PluginUpdateSection: View {
    let model: PluginsViewModel
    let catalog: PluginCatalogViewModel
    let name: String

    private var phase: PluginsViewModel.UpdatePhase? { model.updates[name] }

    var body: some View {
        Section {
            Button {
                Task { await model.update(name, catalog: catalog) }
            } label: {
                HStack {
                    Text("Update")
                    Spacer(minLength: 8)
                    if model.activity[name] == .updating {
                        ProgressView()
                    }
                }
            }
            .disabled(model.activity[name] != nil)
            outcome
        } header: {
            Text("Update")
        } footer: {
            Text("Hermes fetches the new version on the host and scans it before switching.")
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch phase {
        case .running?:
            Text("Updating on your Hermes host…")
                .foregroundStyle(.secondary)
        case .confirming?:
            Text("Hermes may still be working on this. Checking with your Hermes host…")
                .foregroundStyle(.secondary)
        case .needsConsent(let consent)?:
            if let message = consent.message {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .succeeded(let update)?:
            PluginUpdateResultRows(update: update)
        case .failed(let message)?:
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .unknown(let message)?:
            Label(message, systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}

private struct PluginUpdateResultRows: View {
    let update: PluginUpdate?

    var body: some View {
        if update?.unchanged == true {
            Label("Already up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Updated", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        if let sha = update?.sha {
            MCPValueRow(title: "Commit", value: String(sha.prefix(7)))
        }
        if let output = update?.output {
            ScrollView(.horizontal) {
                Text(verbatim: output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        if let update, !update.unchanged {
            Text(update.liveness.map(PluginLabels.liveness) ?? PluginLabels.liveness(.newSessions))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        PluginNoteList(title: "Warnings", items: update?.warnings ?? [])
        PluginNoteList(title: "Python dependencies", items: update?.pythonDependencies ?? [])
    }
}

/// A titled list of host-provided lines, hidden when empty.
struct PluginNoteList: View {
    let title: LocalizedStringKey
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(verbatim: item)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
