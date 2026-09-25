import Foundation
import Observation

/// The MCP servers configured on the user's Hermes host. The list, each server's test, each
/// toggle and each delete load and fail on their own, so a slow probe never holds back the
/// config summary, the toggle or delete. Nothing is optimistic: a toggle shows as pending
/// until the host answers, and a delete counts only once a fresh list no longer has it.
@MainActor @Observable final class MCPServersViewModel {
    enum TestState: Equatable {
        case running
        /// The host answered: connected with its tools, or its probe's error.
        case finished(MCPTestResult)
        /// The request itself failed.
        case failed(DashboardProblem)
    }

    private(set) var servers: [MCPServer] = []
    private(set) var listState: DashboardLoadState = .idle
    private(set) var tests: [String: TestState] = [:]
    /// The value each running toggle asked for. The server keeps its saved value until the host answers.
    private(set) var pendingToggles: [String: Bool] = [:]
    private(set) var toggleProblems: [String: String] = [:]
    /// The server whose delete is running.
    private(set) var deleting: String?
    private(set) var deleteProblems: [String: String] = [:]
    /// Why the device-owner check before a delete could not run, such as no passcode.
    var authenticationProblem: String?

    private let client: DashboardClient
    private let authenticate: @MainActor (String) async -> DeviceOwnerAuthentication.Outcome

    /// The main-actor default is built here rather than in a default argument, which Swift
    /// evaluates outside the actor.
    init(client: DashboardClient,
         authenticate: (@MainActor (String) async -> DeviceOwnerAuthentication.Outcome)? = nil) {
        self.client = client
        self.authenticate = authenticate ?? { await DeviceOwnerAuthentication.confirm(reason: $0) }
    }

    func server(named name: String) -> MCPServer? { servers.first { $0.name == name } }

    /// Plugin servers are read-only on the host, and nothing changes a server being deleted.
    func canChange(_ server: MCPServer) -> Bool { !server.isFromPlugin && deleting != server.name }

    // MARK: - List

    func load(force: Bool = false) async {
        guard listState != .loading, force || listState != .loaded else { return }
        listState = .loading
        do {
            servers = try await client.mcpServers()
            listState = .loaded
        } catch {
            listState = DashboardProblem.isCancellation(error)
                ? (servers.isEmpty ? .idle : .loaded) : .failed(DashboardProblem(error))
        }
    }

    /// A fresh read that confirms a change on the host. It throws rather than keep stale rows.
    @discardableResult
    func refresh() async throws -> [MCPServer] {
        let fresh = try await client.mcpServers()
        servers = fresh
        listState = .loaded
        return fresh
    }

    // MARK: - Test

    /// Connects to the server on the host. A new test clears the previous result first.
    func test(_ name: String) async {
        guard tests[name] != .running else { return }
        tests[name] = .running
        do {
            tests[name] = .finished(try await client.testMCPServer(name))
        } catch {
            tests[name] = DashboardProblem.isCancellation(error) ? nil : .failed(DashboardProblem(error))
        }
    }

    // MARK: - Enable and disable

    /// Applies the host's saved value on success; on failure the toggle snaps back to it.
    func setEnabled(_ name: String, to enabled: Bool) async {
        guard let server = server(named: name), canChange(server), pendingToggles[name] == nil,
              server.enabled != enabled else { return }
        toggleProblems[name] = nil
        pendingToggles[name] = enabled
        defer { pendingToggles[name] = nil }
        do {
            let saved = try await client.setMCPServer(name, enabled: enabled)
            if let index = servers.firstIndex(where: { $0.name == name }) { servers[index].enabled = saved }
        } catch {
            toggleProblems[name] = await problem(error, changing: name)
        }
    }

    // MARK: - Delete

    /// Asks for Face ID or the passcode first. True once a fresh list shows the server gone.
    func delete(_ name: String) async -> Bool {
        guard deleting == nil, let server = server(named: name), canChange(server) else { return false }
        authenticationProblem = nil
        deleteProblems[name] = nil
        switch await authenticate(String(localized: "Confirm removing “\(name)” from your Hermes host.")) {
        case .confirmed: break
        case .cancelled: return false
        case .unavailable(let message):
            authenticationProblem = message
            return false
        }
        deleting = name
        defer { deleting = nil }
        do {
            try await client.deleteMCPServer(name)
        } catch {
            deleteProblems[name] = await problem(error, changing: name)
            return false
        }
        do {
            guard try await refresh().contains(where: { $0.name == name }) == false else {
                deleteProblems[name] = String(localized: "Hermes answered, but “\(name)” is still one of its MCP servers.")
                return false
            }
            tests[name] = nil
            toggleProblems[name] = nil
            return true
        } catch {
            deleteProblems[name] = String(localized: "Hermes answered, but Hermex couldn’t reload the list to confirm “\(name)” is gone. Refresh to check.")
            return false
        }
    }

    /// A 409 means a plugin provides the server, so this list is stale: it rereads it to
    /// name the plugin, and the row turns read-only.
    private func problem(_ error: Error, changing name: String) async -> String {
        guard (error as? BotFailure) == .rejected(409) else { return DashboardProblem(error).message }
        _ = try? await refresh()
        if let plugin = server(named: name)?.plugin {
            return String(localized: "“\(name)” is provided by the plugin “\(plugin)”, so it can’t be changed here. Manage it through the plugin.")
        }
        return String(localized: "“\(name)” is provided by a plugin, so it can’t be changed here. Manage it through the plugin.")
    }
}
