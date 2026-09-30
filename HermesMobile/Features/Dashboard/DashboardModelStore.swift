import Foundation

/// Keeps the Dashboard's view models, and the rows they loaded, for the app session,
/// so coming back to the Dashboard shows the previous lists at once while they refresh.
/// Memory only: MCP servers carry unredacted commands and URLs, so none of this is
/// ever written to disk.
///
/// One bundle at a time, keyed by the active server and the whole saved Bot
/// connection: another server, another connection, or a changed address or password
/// builds a new bundle and drops the old one. Server switch, sign-out, server removal
/// and Bot connection removal drop it explicitly too.
@MainActor final class DashboardModelStore {
    static let shared = DashboardModelStore()

    @MainActor final class Bundle {
        let client: DashboardClient
        let skillsHub: SkillsHubViewModel
        let mcpServers: MCPServersViewModel
        let mcpCatalog: MCPCatalogViewModel
        let plugins: PluginsViewModel
        let pluginCatalog: PluginCatalogViewModel
        /// Loads only when Tools opens, so it stays out of `refreshLists`.
        let tools: ToolsProfilesViewModel
        private var listRefresh: Task<Void, Never>?
        private var listGeneration = 0

        init(client: DashboardClient) {
            self.client = client
            skillsHub = SkillsHubViewModel(client: client)
            mcpServers = MCPServersViewModel(client: client)
            mcpCatalog = MCPCatalogViewModel(client: client, servers: mcpServers)
            plugins = PluginsViewModel(client: client)
            pluginCatalog = PluginCatalogViewModel(client: client, plugins: plugins)
            tools = ToolsProfilesViewModel(client: client)
        }

        /// Loads installed skills, plugins and MCP servers side by side, keeping any rows
        /// already shown. The store owns the task, so opening a section doesn't cancel
        /// it; a call while one runs joins it, and a call once it has finished starts
        /// a new one.
        @discardableResult
        func refreshLists() -> Task<Void, Never> {
            if let listRefresh { return listRefresh }
            listGeneration += 1
            let generation = listGeneration
            let task = Task { [weak self, skillsHub, mcpServers, plugins] in
                async let skills: Void = skillsHub.loadInstalled()
                async let servers: Void = mcpServers.load(force: true)
                async let installed: Void = plugins.load(force: true)
                _ = await (skills, servers, installed)
                // Cleared on the main actor before `value` resolves, and only if no newer
                // refresh replaced this one after `cancel()`.
                if self?.listGeneration == generation { self?.listRefresh = nil }
            }
            listRefresh = task
            return task
        }

        fileprivate func cancel() {
            listRefresh?.cancel()
            listRefresh = nil
        }
    }

    private struct Key: Equatable {
        let server: String
        let connection: BotConnection
    }

    private var current: (key: Key, bundle: Bundle)?
    private let makeClient: (BotConnection) -> DashboardClient

    init(makeClient: ((BotConnection) -> DashboardClient)? = nil) {
        self.makeClient = makeClient ?? { DashboardClient(connection: $0) }
    }

    /// The kept bundle for this server and connection, or a new one that replaces it.
    func bundle(server: URL, connection: BotConnection) -> Bundle {
        let key = Key(server: server.absoluteString, connection: connection)
        if let current, current.key == key { return current.bundle }
        dropAll()
        let bundle = Bundle(client: makeClient(connection))
        current = (key, bundle)
        return bundle
    }

    func drop(server: URL) {
        guard current?.key.server == server.absoluteString else { return }
        dropAll()
    }

    func dropAll() {
        current?.bundle.cancel()
        current = nil
    }
}
