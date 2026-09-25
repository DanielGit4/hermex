import SwiftUI

/// One catalog entry, reviewed before anything is installed: where it comes from and every
/// command, URL, repository and value an install runs or writes on the host, all above the
/// Install button.
struct MCPCatalogDetailView: View {
    let model: MCPCatalogViewModel
    /// The row this opened from; the screen follows the model's copy once the catalog reloads.
    let entry: MCPCatalogEntry

    @State private var isPresentingInstall = false

    private var current: MCPCatalogEntry { model.entry(named: entry.name) ?? entry }

    var body: some View {
        List {
            Section {
                header
            }
            if let source = current.source {
                Section("Source") {
                    if let url = current.sourceURL {
                        Link(destination: url) {
                            Text(verbatim: source)
                                .font(.callout)
                        }
                    } else {
                        Text(verbatim: source)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            Section("Server") {
                MCPInstallCommandRows(entry: current)
                if let auth = MCPLabels.catalogAuth(current.authType) {
                    MCPValueRow(title: "Authentication", value: auth, monospaced: false)
                }
            }
            MCPRepositorySections(entry: current)
            if !current.requiredEnv.isEmpty {
                Section("Environment") {
                    ForEach(current.requiredEnv) { requirement in
                        MCPEnvRequirementRow(requirement: requirement)
                    }
                }
            }
            if let postInstall = current.postInstall {
                Section("After Install") {
                    Text(verbatim: postInstall)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            Section {
                Button {
                    isPresentingInstall = true
                } label: {
                    Group {
                        if current.installed {
                            Text("Reinstall")
                        } else {
                            Text("Install on Hermes Host")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isInstalling)
            } footer: {
                if current.installed {
                    Text("Reinstalling replaces this server’s current configuration on the host.")
                }
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { MCPInstallBanner(model: model) }
        .sheet(isPresented: $isPresentingInstall) {
            MCPInstallSheet(model: model, entry: current)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: current.name)
                .font(.title3.weight(.bold))
            if let description = current.description {
                Text(verbatim: description)
                    .foregroundStyle(.secondary)
            }
            MCPCatalogBadges(entry: current)
        }
        .padding(.vertical, 4)
    }
}

/// Transport, then the command and arguments or the URL the host will connect to.
private struct MCPInstallCommandRows: View {
    let entry: MCPCatalogEntry

    var body: some View {
        MCPValueRow(title: "Transport", value: MCPLabels.transport(entry.transport), monospaced: false)
        if let command = entry.command {
            MCPValueRow(title: "Command", value: command)
        }
        if !entry.args.isEmpty {
            MCPValueRow(title: "Arguments", value: entry.args.joined(separator: "\n"))
        }
        if let url = entry.url {
            MCPValueRow(title: "URL", value: url)
        }
    }
}

/// The repository a git install clones and every bootstrap command it runs there.
private struct MCPRepositorySections: View {
    let entry: MCPCatalogEntry

    var body: some View {
        if let installURL = entry.installURL {
            Section {
                Text(verbatim: entry.installRef.map { "\(installURL) @ \($0)" } ?? installURL)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Repository")
            } footer: {
                Text("Hermes clones this repository on the host, then runs each bootstrap command in it.")
            }
        }
        if !entry.bootstrap.isEmpty {
            Section("Bootstrap Commands") {
                ForEach(Array(entry.bootstrap.enumerated()), id: \.offset) { _, command in
                    Text(verbatim: command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct MCPEnvRequirementRow: View {
    let requirement: MCPCatalogEntry.EnvRequirement

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: requirement.name)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(requirement.isRequired ? String(localized: "Required") : String(localized: "Optional"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let prompt = requirement.prompt {
                Text(verbatim: prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The values and switch one install needs, then a review that repeats what will run. The
/// values live only in this sheet's state: one request carries them to the host, and they
/// are cleared once it returns and whenever the sheet closes.
private struct MCPInstallSheet: View {
    let model: MCPCatalogViewModel
    let entry: MCPCatalogEntry

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var enable = true
    @State private var isReviewing = false
    @State private var isSending = false

    /// A repository install always ends enabled on the host.
    private var willEnable: Bool { entry.needsInstall || enable }

    var body: some View {
        NavigationStack {
            Form {
                if !entry.requiredEnv.isEmpty {
                    Section {
                        ForEach(entry.requiredEnv) { requirement in
                            VStack(alignment: .leading, spacing: 6) {
                                MCPEnvRequirementRow(requirement: requirement)
                                SecureField(text: value(requirement.name), prompt: Text(verbatim: requirement.name)) {
                                    Text(verbatim: requirement.name)
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            }
                        }
                    } header: {
                        Text("Environment")
                    } footer: {
                        Text("Hermex sends these once to your Hermes host, which saves them in its .env. They aren’t kept on this iPhone.")
                    }
                }
                Section {
                    Toggle("Enable after install", isOn: entry.needsInstall ? .constant(true) : $enable)
                        .disabled(entry.needsInstall)
                } footer: {
                    if entry.needsInstall {
                        Text("Hermes always enables a server it installs from a repository. You can turn it off afterwards on the server’s page.")
                    }
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { isReviewing = true }
                        .disabled(!model.canInstall(entry, values: values))
                }
            }
            .navigationDestination(isPresented: $isReviewing) { review }
        }
        .interactiveDismissDisabled(isSending)
        .onDisappear { values = [:] }
    }

    private func value(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private var review: some View {
        let names = MCPCatalogViewModel.environment(for: entry, values: values).keys.sorted()
        return List {
            Section("Server") {
                MCPValueRow(title: "Name", value: entry.name)
                MCPInstallCommandRows(entry: entry)
            }
            MCPRepositorySections(entry: entry)
            Section {
                if names.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    Text(verbatim: name)
                        .font(.callout.monospaced())
                }
            } header: {
                Text("Written to the host’s .env: \(names.count)")
            }
            Section {
                LabeledContent("State after install") {
                    Text(willEnable ? String(localized: "Enabled") : String(localized: "Disabled"))
                }
            } footer: {
                if entry.installed {
                    Text("Reinstalling replaces this server’s current configuration on the host.")
                }
            }
            Section {
                Button(action: send) {
                    HStack(spacing: 8) {
                        if isSending {
                            ProgressView()
                            Text("Sending to your Hermes host…")
                        } else if entry.installed {
                            Text("Reinstall")
                        } else {
                            Text("Install on Hermes Host")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isSending || !model.canInstall(entry, values: values))
            }
        }
        .navigationTitle("Review")
        .navigationBarBackButtonHidden(isSending)
    }

    /// The request carries the values once; the sheet drops them as soon as it returns.
    private func send() {
        isSending = true
        Task {
            await model.install(entry, values: values, enable: willEnable)
            values = [:]
            isSending = false
            dismiss()
        }
    }
}
