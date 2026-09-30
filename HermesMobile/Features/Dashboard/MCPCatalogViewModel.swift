import Foundation
import Observation

/// The host's MCP catalog and the one install it runs at a time. It loads only when the
/// catalog opens, never with the servers list. Install values are a parameter for exactly
/// one request and are never stored here. Success is reported only once the host has
/// finished — its answer, or a background action's exit 0 — and a fresh servers read shows
/// the server.
@MainActor @Observable final class MCPCatalogViewModel {
    enum InstallPhase: Equatable {
        case running
        case succeeded(String)
        case failed(String)
    }

    struct InstallState: Equatable {
        let name: String
        var phase: InstallPhase
        /// A background install's log lines on the host, newest last.
        var lines: [String] = []
    }

    private(set) var entries: [MCPCatalogEntry] = []
    private(set) var diagnostics: [MCPCatalog.Diagnostic] = []
    private(set) var state: DashboardLoadState = .idle
    private(set) var operation: InstallState?
    /// Follows a started install to its outcome once the request carrying the values has returned.
    @ObservationIgnored private(set) var confirmation: Task<Void, Never>?
    /// The host profile every request reads and changes.
    let profile: String

    private let client: DashboardClient
    private let servers: MCPServersViewModel
    private let pollInterval: Duration
    private let maxPolls: Int
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Delays are injected so tests never sleep.
    init(client: DashboardClient,
         profile: String,
         servers: MCPServersViewModel,
         pollInterval: Duration = .seconds(1),
         maxPolls: Int = 600,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.profile = profile
        self.servers = servers
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
        self.sleep = sleep
    }

    var isInstalling: Bool { operation?.phase == .running }

    func entry(named name: String) -> MCPCatalogEntry? { entries.first { $0.name == name } }

    // MARK: - Catalog

    func load(force: Bool = false) async {
        guard state != .loading, force || state != .loaded else { return }
        state = .loading
        do {
            apply(try await client.mcpCatalog(profile: profile))
            state = .loaded
        } catch {
            state = DashboardProblem.isCancellation(error)
                ? (entries.isEmpty ? .idle : .loaded) : .failed(DashboardProblem(error))
        }
    }

    func matching(_ query: String) -> [MCPCatalogEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.description?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func apply(_ catalog: MCPCatalog) {
        entries = catalog.entries
        diagnostics = catalog.diagnostics
    }

    // MARK: - Install

    /// Every required value is filled; optional ones may stay empty.
    static func hasRequiredValues(_ entry: MCPCatalogEntry, values: [String: String]) -> Bool {
        entry.requiredEnv.allSatisfy { !$0.isRequired || environment(for: entry, values: values)[$0.name] != nil }
    }

    /// What the request sends: only names the entry declares (the host refuses any other),
    /// and only non-empty values.
    static func environment(for entry: MCPCatalogEntry, values: [String: String]) -> [String: String] {
        entry.requiredEnv.reduce(into: [:]) { env, requirement in
            if let value = values[requirement.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                env[requirement.name] = value
            }
        }
    }

    func canInstall(_ entry: MCPCatalogEntry, values: [String: String]) -> Bool {
        !isInstalling && Self.hasRequiredValues(entry, values: values)
    }

    /// Sends the install and returns once the host has answered that request, so the caller
    /// can drop the values; `confirmation` then follows the install to its outcome.
    func install(_ entry: MCPCatalogEntry, values: [String: String], enable: Bool) async {
        guard canInstall(entry, values: values) else { return }
        operation = InstallState(name: entry.name, phase: .running)
        do {
            // Signing in first separates "never sent" from "sent, then lost".
            try await client.signIn()
        } catch {
            return finish(.failed(DashboardProblem(error).message))
        }
        let start: MCPInstallStart
        do {
            // A git-bootstrapped install always ends enabled on the host, whatever `enable` says.
            start = try await client.installMCPCatalogEntry(entry.name, env: Self.environment(for: entry, values: values),
                                                            enable: entry.needsInstall || enable, profile: profile)
        } catch {
            return finish(.failed(Self.requestProblem(error, name: entry.name)))
        }
        confirmation = Task { await self.confirm(entry.name, start) }
    }

    func dismissInstallResult() {
        guard !isInstalling else { return }
        operation = nil
    }

    private func confirm(_ name: String, _ start: MCPInstallStart) async {
        do {
            if case .background(let action) = start {
                guard let status = try await poll(action) else {
                    return finish(.failed(String(localized: "Hermes is still working on this. Refresh later to see how it ended.")))
                }
                guard let exitCode = status.exitCode else {
                    return finish(.failed(String(localized: "Hermes couldn’t report how this ended. Refresh to check.")))
                }
                guard exitCode == 0 else {
                    return finish(.failed(String(localized: "Hermes reported a failure (exit code \(exitCode)).")))
                }
            }
            guard try await servers.refresh().contains(where: { $0.name == name }) else {
                return finish(.failed(String(localized: "Hermes finished, but “\(name)” isn’t installed. The host may have refused it.")))
            }
            // Installed and enabled badges; the install stands even if this read fails.
            if let catalog = try? await client.mcpCatalog(profile: profile) { apply(catalog) }
            finish(.succeeded(String(localized: "Installed “\(name)” on your Hermes host.")))
        } catch {
            finish(.failed(Self.lostContact))
        }
    }

    /// Polls until the action exits; nil when it is still running after `maxPolls`.
    private func poll(_ action: String) async throws -> DashboardActionStatus? {
        for attempt in 0..<maxPolls {
            if attempt > 0 { try await sleep(pollInterval) }
            let status = try await client.actionStatus(action)
            operation?.lines = status.lines
            if !status.running { return status }
        }
        return nil
    }

    private func finish(_ phase: InstallPhase) {
        operation?.phase = phase
    }

    /// A host that answered with an error installed nothing; a request that never reached
    /// it changed nothing. Anything else may have reached the host and may still finish.
    private static func requestProblem(_ error: Error, name: String) -> String {
        switch error {
        case BotFailure.rejected(400):
            return String(localized: "Your Hermes host refused to install “\(name)”. Check the values you entered, then try again.")
        case BotFailure.rejected:
            return DashboardProblem(error).message
        case let error as URLError where unsentCodes.contains(error.code):
            return DashboardProblem(error).message
        default:
            return lostContact
        }
    }

    private static let unsentCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed,
        .internationalRoamingOff
    ]

    private static var lostContact: String {
        String(localized: "Lost contact with your Hermes host while it was working. It may still finish; refresh to check.")
    }
}
