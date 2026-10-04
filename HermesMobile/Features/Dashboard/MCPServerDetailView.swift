import SwiftUI

/// One MCP server on the Hermes host. The config summary renders from the list row at once;
/// the test, the toggle and delete each run and fail on their own. Plugin servers are
/// read-only, and say so.
struct MCPServerDetailView: View {
    let model: MCPServersViewModel
    /// The row this opened from; the screen follows the model's copy once it changes.
    let server: MCPServer

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    private var current: MCPServer { model.server(named: server.name) ?? server }

    var body: some View {
        List {
            statusSection
            configurationSection
            if !current.env.isEmpty {
                environmentSection
            }
            testSection
            if !current.isFromPlugin {
                deleteSection
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "Delete “\(server.name)”?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete(server.name) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes “\(server.name)” from your Hermes host’s MCP configuration. New sessions won’t load its tools. Credentials it saved in the host’s .env, and any repository it cloned, stay.")
        }
        .alert("Couldn’t Confirm It’s You", isPresented: authenticationProblemIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.authenticationProblem ?? "")
        }
    }

    private var authenticationProblemIsPresented: Binding<Bool> {
        Binding(get: { model.authenticationProblem != nil }, set: { if !$0 { model.authenticationProblem = nil } })
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if current.isFromPlugin {
            Section {
                LabeledContent("Status") {
                    Text(current.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                }
            } footer: {
                if let plugin = current.plugin {
                    Text("The plugin “\(plugin)” provides this server, so it can’t be turned off or removed here. Manage it through the plugin.")
                } else {
                    Text("A plugin provides this server, so it can’t be turned off or removed here. Manage it through the plugin.")
                }
            }
        } else {
            Section {
                Toggle(isOn: enabledBinding) {
                    HStack(spacing: 8) {
                        Text("Enabled")
                        if model.pendingToggles[server.name] != nil {
                            ProgressView()
                        }
                    }
                }
                .disabled(!model.canChange(current) || model.pendingToggles[server.name] != nil)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = model.toggleProblems[server.name] {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                    Text("Changes apply to new sessions and after the gateway restarts.")
                }
            }
        }
    }

    /// Shows the value asked for while the host saves it; the saved value otherwise.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.pendingToggles[server.name] ?? current.enabled },
                set: { enabled in Task { await model.setEnabled(server.name, to: enabled) } })
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        Section("Configuration") {
            MCPServerConfigurationRows(server: current)
            MCPValueRow(title: "Tools", value: MCPLabels.toolFilter(current.toolFilter), monospaced: false)
        }
    }

    private var environmentSection: some View {
        Section {
            ForEach(current.env) { variable in
                MCPRedactedEnvRow(variable: variable)
            }
        } header: {
            Text("Environment")
        } footer: {
            Text("Your Hermes host redacts these values. Hermex can’t reveal them.")
        }
    }

    // MARK: - Test

    private var testState: MCPServersViewModel.TestState? { model.tests[server.name] }

    private var testSection: some View {
        Section {
            Button {
                Task { await model.test(server.name) }
            } label: {
                HStack {
                    if testFailed {
                        Text("Retry")
                    } else {
                        Text("Test Connection")
                    }
                    Spacer(minLength: 8)
                    if testState == .running {
                        ProgressView()
                    }
                }
            }
            .disabled(testState == .running)

            switch testState {
            case .finished(.connected(let tools, let prompts, let resources))?:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Tools: \(tools.count) · Prompts: \(prompts) · Resources: \(resources)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if tools.isEmpty {
                    Text("The server offers no tools.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: tool.name)
                            .font(.callout.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        if let description = tool.description {
                            Text(verbatim: description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            case .finished(.failed(let error))?:
                Label("Couldn’t Connect", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                if let error {
                    Text(verbatim: error)
                        .font(.callout)
                        .textSelection(.enabled)
                } else {
                    Text("Your Hermes host gave no reason.")
                        .foregroundStyle(.secondary)
                }
            case .failed(let problem)?:
                Label(problem.message, systemImage: problem.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .running?, nil:
                EmptyView()
            }
        } header: {
            Text("Tools")
        }
    }

    private var testFailed: Bool {
        switch testState {
        case .finished(.failed)?, .failed?: return true
        default: return false
        }
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                HStack {
                    Text("Delete")
                    Spacer(minLength: 8)
                    if model.deleting == server.name {
                        ProgressView()
                    }
                }
            }
            .disabled(model.deleting != nil)
        } footer: {
            if let problem = model.deleteProblems[server.name] {
                Text(problem)
            }
        }
    }
}
