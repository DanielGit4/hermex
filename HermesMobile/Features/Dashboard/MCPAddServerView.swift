import SwiftUI

/// Adds an MCP server to one profile by hand: a form, a review that repeats exactly what the
/// host will save and run, then the host's own summary of the new server. Secrets go into
/// `SecureField`s bound only to the sheet's draft; they are never shown again, and are cleared
/// once sent and whenever the sheet closes.
struct MCPAddServerView: View {
    @Bindable var model: MCPAddServerViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isReviewing = false

    var body: some View {
        NavigationStack {
            MCPAddServerForm(model: model)
                .navigationTitle("Add MCP Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Review") {
                            model.beginReview()
                            isReviewing = true
                        }
                        .disabled(model.draft.problem != nil)
                    }
                }
                .navigationDestination(isPresented: $isReviewing) {
                    MCPAddServerReview(model: model) { dismiss() }
                }
        }
        .interactiveDismissDisabled(model.phase == .sending)
        .onDisappear { model.discardSecrets() }
    }
}

/// Shown under the form, in review and on the added summary of an OAuth server.
private func oauthNote() -> Text {
    Text("Hermes can’t connect to this server until it’s signed in. Sign in from Hermes on your Mac.")
}

private struct MCPAddServerForm: View {
    @Bindable var model: MCPAddServerViewModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Transport", selection: $model.draft.mode) {
                    Text("URL").tag(MCPServerDraft.Mode.url)
                    Text("Command").tag(MCPServerDraft.Mode.command)
                }
                .pickerStyle(.segmented)
            }
            switch model.draft.mode {
            case .url: urlSection
            case .command: commandSections
            }
        }
    }

    private var urlSection: some View {
        Section {
            TextField("URL", text: $model.draft.url)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Authentication", selection: $model.draft.auth) {
                Text("None").tag(MCPServerDraft.Auth.none)
                Text("Bearer token").tag(MCPServerDraft.Auth.bearer)
                Text(verbatim: "OAuth").tag(MCPServerDraft.Auth.oauth)
            }
            if model.draft.auth == .bearer {
                SecureField("Bearer token", text: $model.draft.bearerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } footer: {
            footer {
                switch model.draft.auth {
                case .bearer:
                    Text("Your Hermes host saves the token in this profile’s .env, and its config refers to it. Hermex doesn’t keep it.")
                case .oauth:
                    oauthNote()
                case .none:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var commandSections: some View {
        Section {
            TextField("Command", text: $model.draft.command)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Section {
            ForEach($model.draft.args) { $argument in
                HStack(spacing: 8) {
                    TextField("Argument", text: $argument.value)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    removeButton { model.draft.args.removeAll { $0.id == argument.id } }
                }
            }
            Button {
                model.draft.args.append(MCPServerDraft.Argument())
            } label: {
                Label("Add Argument", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Arguments")
        } footer: {
            Text("Each row is one argument, sent exactly as typed.")
        }
        Section {
            ForEach($model.draft.env) { $entry in
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    TextField("Name", text: $entry.name)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Value", text: $entry.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    removeButton { model.draft.env.removeAll { $0.id == entry.id } }
                }
            }
            Button {
                model.draft.env.append(MCPServerDraft.EnvEntry())
            } label: {
                Label("Add Variable", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Environment")
        } footer: {
            footer {
                Text("Your Hermes host saves these values in this profile’s config.yaml.")
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Remove"))
    }

    /// The last section's note, then why the secrets are empty again and what blocks review.
    private func footer<Note: View>(@ViewBuilder note: () -> Note) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            note()
            if model.secretsWereCleared {
                Text("Hermex cleared the secrets you entered. Enter them again to try again.")
            }
            if let problem = model.draft.problem {
                Text(problem.message)
            }
        }
    }
}

/// Exactly what the host will save and run, read from the request body itself, then the
/// host's summary once it has saved the server.
private struct MCPAddServerReview: View {
    @Bindable var model: MCPAddServerViewModel
    let done: () -> Void

    private var isLocked: Bool {
        if case .added = model.phase { return true }
        return model.phase == .sending
    }

    var body: some View {
        Group {
            if case .added(let server) = model.phase {
                MCPAddedServerSummary(server: server, needsSignIn: model.needsSignIn)
                    .navigationTitle(Text(verbatim: server.name))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: done)
                        }
                    }
            } else {
                review
                    .navigationTitle("Review")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isLocked)
        .alert("Couldn’t Confirm It’s You", isPresented: authenticationProblemIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.authenticationProblem ?? "")
        }
    }

    private var authenticationProblemIsPresented: Binding<Bool> {
        Binding(get: { model.authenticationProblem != nil }, set: { if !$0 { model.authenticationProblem = nil } })
    }

    private var review: some View {
        let draft = model.draft
        let request = draft.body
        let args = (request["args"].list ?? []).compactMap(\.text)
        let envNames = (request["env"].fields ?? [:]).keys.sorted()
        return List {
            Section {
                MCPValueRow(title: "Name", value: request["name"].text ?? "")
                if let url = request["url"].text {
                    MCPValueRow(title: "URL", value: url)
                    MCPValueRow(title: "Authentication", value: authLabel(draft.auth), monospaced: false)
                    if draft.auth == .bearer, draft.hasSecrets {
                        MCPValueRow(title: "Bearer token", value: String(localized: "Entered (not shown)"), monospaced: false)
                    }
                }
                if let command = request["command"].text {
                    MCPValueRow(title: "Command", value: command)
                    if !args.isEmpty {
                        MCPValueRow(title: "Arguments", value: args.joined(separator: "\n"))
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                if draft.mode == .url, draft.auth == .oauth {
                    oauthNote()
                }
            }
            if draft.mode == .command {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Runs on your Mac")
                                .font(.headline)
                            Text("Hermes starts this command on your Mac for every new session.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "terminal")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !envNames.isEmpty {
                    Section {
                        ForEach(envNames, id: \.self) { name in
                            Text(verbatim: name)
                                .font(.callout.monospaced())
                        }
                    } header: {
                        Text("Environment")
                    } footer: {
                        Text("Your Hermes host saves these values in this profile’s config.yaml.")
                    }
                }
            }
            Section {
                Button {
                    Task { await model.submit() }
                } label: {
                    HStack(spacing: 8) {
                        if model.phase == .sending {
                            ProgressView()
                            Text("Sending to your Hermes host…")
                        } else {
                            Text("Add to Hermes Host")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.canSubmit)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if case .failed(let message) = model.phase {
                        Text(verbatim: message)
                            .foregroundStyle(.red)
                    }
                    if model.secretsWereCleared {
                        Text("Hermex cleared the secrets you entered. Enter them again to try again.")
                    }
                }
            }
        }
    }

    private func authLabel(_ auth: MCPServerDraft.Auth) -> String {
        switch auth {
        case .none: return String(localized: "None")
        case .bearer: return String(localized: "Bearer token")
        case .oauth: return "OAuth"
        }
    }
}

/// The host's own summary of the server it saved, env values already redacted by the host.
private struct MCPAddedServerSummary: View {
    let server: MCPServer
    let needsSignIn: Bool

    var body: some View {
        List {
            Section {
                Label {
                    Text("Added “\(server.name)” to your Hermes host.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if needsSignIn {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next: Sign In")
                                .font(.headline)
                            oauthNote()
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.badge.key")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                MCPServerConfigurationRows(server: server)
            } header: {
                Text("Configuration")
            } footer: {
                Text("Changes apply to new sessions and after the gateway restarts.")
            }
            if !server.env.isEmpty {
                Section {
                    ForEach(server.env) { variable in
                        MCPRedactedEnvRow(variable: variable)
                    }
                } header: {
                    Text("Environment")
                } footer: {
                    Text("Your Hermes host redacts these values. Hermex can’t reveal them.")
                }
            }
        }
    }
}
