import Foundation
import Observation

/// One add-server sheet on a profile's MCP screen. The draft, secrets included, lives only
/// here and is never persisted; the secrets are cleared before the request is awaited, so
/// they are gone whatever the outcome. Success shows only once the host's summary of the new
/// server decodes, and that row lands in the profile's `MCPServersViewModel`.
@MainActor @Observable final class MCPAddServerViewModel: Identifiable {
    enum Phase: Equatable {
        case editing
        case sending
        /// The host's summary of the server it saved, env already redacted.
        case added(MCPServer)
        case failed(String)
    }

    var draft = MCPServerDraft()
    private(set) var phase = Phase.editing
    /// Why the device-owner check before sending secrets could not run, such as no passcode.
    var authenticationProblem: String?
    /// The last submit cleared secrets it sent, so they have to be entered again.
    private(set) var secretsWereCleared = false

    private let client: DashboardClient
    private let servers: MCPServersViewModel
    private let authenticate: @MainActor (String) async -> DeviceOwnerAuthentication.Outcome

    /// The main-actor default is built here rather than in a default argument, which Swift
    /// evaluates outside the actor.
    init(client: DashboardClient, servers: MCPServersViewModel,
         authenticate: (@MainActor (String) async -> DeviceOwnerAuthentication.Outcome)? = nil) {
        self.client = client
        self.servers = servers
        self.authenticate = authenticate ?? { await DeviceOwnerAuthentication.confirm(reason: $0) }
    }

    var profile: String { servers.profile }

    /// Cleared secrets must be entered again, and reviewed, before another submit.
    var canSubmit: Bool { phase != .sending && !secretsWereCleared && draft.problem == nil }

    /// The host can't connect to an OAuth server until someone signs in to it.
    var needsSignIn: Bool {
        if case .added(let server) = phase { return server.auth == "oauth" }
        return false
    }

    /// Opening the review again starts a fresh attempt.
    func beginReview() {
        guard phase != .sending else { return }
        if case .added = phase { return }
        phase = .editing
        authenticationProblem = nil
        secretsWereCleared = false
    }

    func submit() async {
        guard canSubmit else { return }
        authenticationProblem = nil
        let name = draft.trimmedName
        let sendsSecrets = draft.hasSecrets
        if sendsSecrets {
            switch await authenticate(String(localized: "Confirm sending secrets for “\(name)” to your Hermes host.")) {
            case .confirmed:
                break
            case .cancelled:
                phase = .editing
                return
            case .unavailable(let message):
                authenticationProblem = message
                phase = .editing
                return
            }
        }
        // The body is the only copy that leaves the draft; it lives as long as the request.
        let body = draft.body
        draft.clearSecrets()
        secretsWereCleared = sendsSecrets
        phase = .sending
        switch await PluginRequest.send(client, { try await self.client.addMCPServer(body, profile: self.profile) }) {
        case .answered(let server):
            servers.insertAdded(server)
            phase = .added(server)
            // The host already confirmed it, so a failed reload keeps the row and the success.
            await servers.load(force: true)
        case .failed(let error):
            phase = .failed(Self.message(for: error, name: name))
        case .lostContact:
            phase = .failed(PluginRequest.lostContact)
        }
    }

    /// Clears the secrets when the sheet closes.
    func discardSecrets() {
        draft.clearSecrets()
    }

    /// A refusal shows the host's own words, as sent.
    private static func message(for error: Error, name: String) -> String {
        switch error {
        case DashboardFailure.refused(let detail):
            if let reason = DashboardFailure.refusalMessage(detail) { return reason }
            fallthrough
        case BotFailure.rejected(400), BotFailure.rejected(409):
            return String(localized: "Your Hermes host refused to add “\(name)”.")
        default:
            return DashboardProblem(error).message
        }
    }
}
