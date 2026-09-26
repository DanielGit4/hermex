import Foundation
import Observation

/// The agent plugins installed on the user's Hermes host. The list, each toggle, update and
/// remove load and fail on their own, and one plugin runs one of them at a time. Nothing is
/// optimistic: a toggle shows as pending until the host answers and a fresh list shows its
/// status, and a removal counts only once a fresh list no longer has the plugin.
@MainActor @Observable final class PluginsViewModel {
    /// What is running on one plugin.
    enum Activity: Equatable {
        case toggling(to: Bool)
        case updating
        case removing
    }

    /// How the last toggle ended, for the note under the switch.
    enum ToggleOutcome: Equatable {
        case unchanged(enabled: Bool)
        case enabled(PluginLiveness)
        /// Config-only: running sessions keep the plugin until Hermes restarts.
        case disabled
    }

    enum UpdatePhase: Equatable {
        case running
        /// Contact was lost after sending; rereading the host to learn what happened.
        case confirming
        /// Nothing changed: the update adds capabilities the user has to accept first.
        case needsConsent(PluginConsent)
        /// The host's answer, or nil when a reread after lost contact showed the new commit.
        case succeeded(PluginUpdate?)
        case failed(String)
        /// The host may still be working; neither success nor failure is known.
        case unknown(String)
    }

    private(set) var plugins: [AgentPlugin] = []
    private(set) var listState: DashboardLoadState = .idle
    private(set) var activity: [String: Activity] = [:]
    private(set) var toggleOutcomes: [String: ToggleOutcome] = [:]
    private(set) var toggleProblems: [String: String] = [:]
    private(set) var updates: [String: UpdatePhase] = [:]
    private(set) var removeProblems: [String: String] = [:]
    /// The last confirmed removal, shown on the list a removed plugin's page returns to.
    private(set) var removalNotice: String?
    /// Why the device-owner check before a removal could not run, such as no passcode.
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

    func plugin(named name: String) -> AgentPlugin? { plugins.first { $0.name == name } }

    /// The value a running toggle asked for; the plugin keeps the host's status until it answers.
    func pendingToggle(_ name: String) -> Bool? {
        if case .toggling(let enabled)? = activity[name] { return enabled }
        return nil
    }

    /// A git checkout pulls; a catalog plugin re-pins when the catalog has a newer commit.
    static func canUpdate(_ plugin: AgentPlugin, catalogEntry: PluginCatalogEntry?) -> Bool {
        plugin.canUpdateGit || catalogEntry?.updateAvailable == true
    }

    // MARK: - List

    func load(force: Bool = false) async {
        guard listState != .loading, force || listState != .loaded else { return }
        listState = .loading
        if force { removalNotice = nil }
        do {
            plugins = try await client.pluginsHub()
            listState = .loaded
        } catch {
            listState = DashboardProblem.isCancellation(error)
                ? (plugins.isEmpty ? .idle : .loaded) : .failed(DashboardProblem(error))
        }
    }

    /// A fresh read that confirms a change on the host. It throws rather than keep stale rows.
    @discardableResult
    func refresh() async throws -> [AgentPlugin] {
        let fresh = try await client.pluginsHub()
        plugins = fresh
        listState = .loaded
        return fresh
    }

    // MARK: - Enable and disable

    /// Applies the status a fresh list shows; on failure the toggle snaps back to it.
    func setEnabled(_ name: String, to enabled: Bool) async {
        guard activity[name] == nil, let plugin = plugin(named: name), plugin.isEnabled != enabled else { return }
        toggleProblems[name] = nil
        toggleOutcomes[name] = nil
        activity[name] = .toggling(to: enabled)
        defer { activity[name] = nil }
        switch await PluginRequest.send(client, { try await self.client.setPlugin(name, enabled: enabled) }) {
        case .answered(let result):
            toggleOutcomes[name] = result.unchanged ? .unchanged(enabled: enabled)
                : (enabled ? .enabled(result.liveness) : .disabled)
            do {
                try await refresh()
            } catch {
                // The host saved it; show what it confirmed until the list can be read again.
                if let index = plugins.firstIndex(where: { $0.name == name }) {
                    plugins[index].runtimeStatus = enabled ? "enabled" : "disabled"
                }
            }
        case .failed(let error):
            toggleProblems[name] = DashboardProblem(error).message
        case .lostContact:
            toggleProblems[name] = String(localized: "Lost contact with your Hermes host, so it may have applied this change. Pull to refresh to see its current state.")
            _ = try? await refresh()
        }
    }

    // MARK: - Update

    /// Updates on the host. A re-pin that adds capabilities stops at `needsConsent`; only the
    /// user's confirmation sends it again with `acceptingCapabilities`. `catalog` rereads the
    /// catalog, which is how a lost request's outcome is learned.
    func update(_ name: String, catalog: PluginCatalogViewModel, acceptingCapabilities: Bool = false) async {
        guard activity[name] == nil, plugin(named: name) != nil else { return }
        if acceptingCapabilities {
            guard case .needsConsent? = updates[name] else { return }
        }
        let before = catalog.catalog.entry(installedAs: name)
        activity[name] = .updating
        updates[name] = .running
        defer { activity[name] = nil }
        switch await PluginRequest.send(client, {
            try await self.client.updatePlugin(name, acceptCapabilities: acceptingCapabilities)
        }) {
        case .answered(.needsConsent(let consent)):
            updates[name] = .needsConsent(consent)
        case .answered(.updated(let update)):
            updates[name] = .succeeded(update)
            _ = try? await refresh()
            if catalog.state != .idle { _ = try? await catalog.refresh() }
        case .failed(let error):
            updates[name] = .failed(DashboardProblem(error).message)
        case .lostContact:
            updates[name] = .confirming
            updates[name] = await confirmUpdate(name, before: before, catalog: catalog)
        }
    }

    /// Cancelling a consent sends nothing.
    func cancelConsent(_ name: String) {
        guard case .needsConsent? = updates[name] else { return }
        updates[name] = nil
    }

    /// Only the catalog can show a lost update landed: its update flag cleared, or its
    /// installed commit moved. A git pull, or a failed reread, stays unknown.
    private func confirmUpdate(_ name: String, before: PluginCatalogEntry?,
                               catalog: PluginCatalogViewModel) async -> UpdatePhase {
        _ = try? await refresh()
        guard let fresh = try? await catalog.refresh(), let before,
              let after = fresh.entry(installedAs: name) else {
            return .unknown(PluginRequest.stillWorking)
        }
        let moved = after.installedSHA != nil && after.installedSHA != before.installedSHA
        return (before.updateAvailable && !after.updateAvailable) || moved
            ? .succeeded(nil) : .unknown(PluginRequest.stillWorking)
    }

    // MARK: - Remove

    /// Asks for Face ID or the passcode first. True once a fresh list shows the plugin gone.
    func remove(_ name: String) async -> Bool {
        guard activity[name] == nil, let plugin = plugin(named: name), plugin.canRemove else { return false }
        authenticationProblem = nil
        removeProblems[name] = nil
        switch await authenticate(String(localized: "Confirm removing “\(name)” from your Hermes host.")) {
        case .confirmed: break
        case .cancelled: return false
        case .unavailable(let message):
            authenticationProblem = message
            return false
        }
        guard activity[name] == nil else { return false }
        activity[name] = .removing
        defer { activity[name] = nil }
        switch await PluginRequest.send(client, { try await self.client.removePlugin(name) }) {
        case .answered(let result):
            do {
                guard try await refresh().contains(where: { $0.name == name }) == false else {
                    removeProblems[name] = String(localized: "Hermes answered, but “\(name)” is still one of its plugins.")
                    return false
                }
            } catch {
                removeProblems[name] = String(localized: "Hermes answered, but Hermex couldn’t reload the list to confirm “\(name)” is gone. Refresh to check.")
                return false
            }
            finishRemoval(name, clearedMemoryProvider: result.clearedMemoryProvider)
            return true
        case .failed(let error):
            removeProblems[name] = DashboardProblem(error).message
            return false
        case .lostContact:
            // It may have gone through; only the host's list can say.
            if let fresh = try? await refresh(), !fresh.contains(where: { $0.name == name }) {
                finishRemoval(name, clearedMemoryProvider: false)
                return true
            }
            removeProblems[name] = PluginRequest.lostContact
            return false
        }
    }

    private func finishRemoval(_ name: String, clearedMemoryProvider: Bool) {
        toggleOutcomes[name] = nil
        toggleProblems[name] = nil
        updates[name] = nil
        removalNotice = clearedMemoryProvider
            ? String(localized: "Removed “\(name)” from your Hermes host. Hermes also reset its memory provider, which used this plugin.")
            : String(localized: "Removed “\(name)” from your Hermes host.")
    }
}

/// Sends one plugin mutation. Signing in first separates "never sent" from "sent, then lost":
/// only a lost request may have changed the host, so its outcome is learned by rereading the
/// host rather than reported.
enum PluginRequest {
    enum Outcome<Value> {
        case answered(Value)
        /// Nothing changed: the host refused or answered with an error, or was never reached.
        case failed(Error)
        /// The request may have reached the host, which may still be working on it.
        case lostContact
    }

    @MainActor static func send<Value>(_ client: DashboardClient,
                                       _ request: () async throws -> Value) async -> Outcome<Value> {
        do {
            try await client.signIn()
        } catch {
            return .failed(error)
        }
        do {
            return .answered(try await request())
        } catch {
            return mayHaveReachedHost(error) ? .lostContact : .failed(error)
        }
    }

    static func mayHaveReachedHost(_ error: Error) -> Bool {
        switch error {
        case DashboardFailure.refused:
            return false
        // A proxy's gateway error is not Hermes's answer: Hermes may still be working.
        case BotFailure.rejected(502...504), BotFailure.rejected(520...530):
            return true
        case BotFailure.rejected:
            return false
        case let error as URLError:
            return !unsentCodes.contains(error.code)
        default:
            // An unreadable answer, a cancelled request or a dropped transport.
            return true
        }
    }

    private static let unsentCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed,
        .internationalRoamingOff
    ]

    static var lostContact: String {
        String(localized: "Lost contact with your Hermes host while it was working. It may still finish; refresh to check.")
    }

    static var stillWorking: String {
        String(localized: "Hermes may still be working on this. Pull to refresh later to see how it ended.")
    }
}
