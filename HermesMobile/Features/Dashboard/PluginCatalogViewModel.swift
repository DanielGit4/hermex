import Foundation
import Observation

/// The host's curated plugin catalog and the one install it runs at a time. It loads on its
/// own — never with the installed list — so a slow or failing catalog holds nothing back.
/// "Installed" is reported only once a fresh hub read lists the plugin, and a request that
/// lost contact ends in whatever a reread of the host shows, never a guessed failure.
@MainActor @Observable final class PluginCatalogViewModel {
    enum TierFilter: String, CaseIterable, Identifiable {
        case all, official, community
        var id: Self { self }
    }

    enum InstallPhase: Equatable {
        case running
        /// Contact was lost after sending; rereading the host to learn what happened.
        case confirming
        /// A fresh hub read lists the plugin. The host's answer, when Hermex received it.
        case succeeded(PluginInstallResult?)
        case failed(String)
        /// The host's security scan refused it.
        case blocked(PluginScanBlock)
        /// The host may still be working; neither success nor failure is known.
        case unknown(String)
    }

    struct InstallState: Equatable {
        /// The catalog entry's name.
        let name: String
        let title: String
        var phase: InstallPhase
    }

    private(set) var catalog = PluginCatalog()
    private(set) var state: DashboardLoadState = .idle
    private(set) var operation: InstallState?

    private let client: DashboardClient
    private let plugins: PluginsViewModel

    init(client: DashboardClient, plugins: PluginsViewModel) {
        self.client = client
        self.plugins = plugins
    }

    var entries: [PluginCatalogEntry] { catalog.entries }

    var isInstalling: Bool { operation?.phase == .running || operation?.phase == .confirming }

    func entry(named name: String) -> PluginCatalogEntry? { catalog.entry(named: name) }

    // MARK: - Catalog

    func load(force: Bool = false) async {
        guard state != .loading, force || state != .loaded else { return }
        state = .loading
        do {
            catalog = try await client.pluginCatalog()
            state = .loaded
        } catch {
            state = DashboardProblem.isCancellation(error)
                ? (entries.isEmpty ? .idle : .loaded) : .failed(DashboardProblem(error))
        }
    }

    /// A fresh read for confirming a change. It throws rather than keep stale entries.
    @discardableResult
    func refresh() async throws -> PluginCatalog {
        let fresh = try await client.pluginCatalog()
        catalog = fresh
        state = .loaded
        return fresh
    }

    /// Entries of a tier whose name, title, description or category contains the query.
    /// A tier this build doesn't know shows only under All.
    func matching(_ query: String, tier: TierFilter) -> [PluginCatalogEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard tier == .all || entry.tier == tier.rawValue else { return false }
            return query.isEmpty || [entry.name, entry.displayTitle, entry.description, entry.category].contains {
                $0?.localizedCaseInsensitiveContains(query) == true
            }
        }
    }

    // MARK: - Install

    /// The host refuses an installed entry without `force`, and never installs a pulled one.
    func canInstall(_ entry: PluginCatalogEntry) -> Bool {
        !isInstalling && !entry.installed && catalog.removal(for: entry) == nil
    }

    func install(_ entry: PluginCatalogEntry, enable: Bool) async {
        guard canInstall(entry) else { return }
        operation = InstallState(name: entry.name, title: entry.displayTitle, phase: .running)
        switch await PluginRequest.send(client, {
            try await self.client.installCatalogPlugin(entry.name, enable: enable)
        }) {
        case .answered(let result):
            finish(await confirm(result, entry: entry))
        case .failed(let error):
            if case DashboardFailure.refused(let detail) = error, let block = PluginScanBlock(detail) {
                finish(.blocked(block))
            } else {
                finish(.failed(DashboardProblem(error).message))
            }
        case .lostContact:
            finish(.confirming)
            finish(await confirmAfterLostContact(entry))
        }
    }

    func dismissInstallResult() {
        guard !isInstalling else { return }
        operation = nil
    }

    /// `ok` alone isn't success: only a fresh hub read that lists the plugin is.
    private func confirm(_ result: PluginInstallResult, entry: PluginCatalogEntry) async -> InstallPhase {
        let name = result.pluginName ?? entry.name
        do {
            guard try await plugins.refresh().contains(where: { $0.name == name }) else {
                return .failed(String(localized: "Hermes answered, but “\(name)” isn’t in its plugins list."))
            }
        } catch {
            return .unknown(String(localized: "Hermes answered, but Hermex couldn’t reload its plugins to confirm. Pull to refresh to check."))
        }
        // Installed badges; the install stands even if this read fails.
        _ = try? await refresh()
        return .succeeded(result)
    }

    /// The entry was not installed when this started, so the catalog now marking it
    /// installed, or the hub listing its name, shows the install landed.
    private func confirmAfterLostContact(_ entry: PluginCatalogEntry) async -> InstallPhase {
        let hub = try? await plugins.refresh()
        let fresh = try? await refresh()
        if fresh?.entry(named: entry.name)?.installed == true || hub?.contains(where: { $0.name == entry.name }) == true {
            return .succeeded(nil)
        }
        return .unknown(PluginRequest.stillWorking)
    }

    private func finish(_ phase: InstallPhase) {
        operation?.phase = phase
    }
}
