import Foundation

/// Keeps the Dashboard's view models, and the rows they loaded, for the app session,
/// so coming back to the Dashboard shows the previous lists at once while they refresh.
/// Memory only: MCP servers carry unredacted commands and URLs, so none of this is
/// ever written to disk.
///
/// One bundle at a time, keyed by the active server and the whole saved Bot
/// connection: another server, another connection, or a changed address or password
/// builds a new bundle and drops the old one. Server switch, sign-out, server removal
/// and Bot connection removal drop it explicitly too, and a bundle whose shared
/// `HermesConnection` was retired is rebuilt on next use. Inside a bundle, each host profile
/// has its own Skills Hub and MCP models, so one profile's rows never show under another.
@MainActor final class DashboardModelStore {
    static let shared = DashboardModelStore()

    /// One host profile's Skills Hub and MCP screens, sharing the bundle's signed-in client.
    /// Every request they make names `profile`.
    @MainActor final class ProfileModels {
        let profile: String
        let skillsHub: SkillsHubViewModel
        let mcpServers: MCPServersViewModel
        let mcpCatalog: MCPCatalogViewModel

        init(profile: String, client: DashboardClient) {
            self.profile = profile
            skillsHub = SkillsHubViewModel(client: client, profile: profile)
            mcpServers = MCPServersViewModel(client: client, profile: profile)
            mcpCatalog = MCPCatalogViewModel(client: client, profile: profile, servers: mcpServers)
        }
    }

    @MainActor final class Bundle {
        let client: DashboardClient
        /// Unscoped: the host's plugin writes take no profile.
        let plugins: PluginsViewModel
        let pluginCatalog: PluginCatalogViewModel
        /// Loads only when Profiles opens, so it stays out of `refreshLists`.
        let tools: ToolsProfilesViewModel
        private var profiles: [String: ProfileModels] = [:]
        private var listRefresh: Task<Void, Never>?
        private var listGeneration = 0

        init(client: DashboardClient) {
            self.client = client
            plugins = PluginsViewModel(client: client)
            pluginCatalog = PluginCatalogViewModel(client: client, plugins: plugins)
            tools = ToolsProfilesViewModel(client: client)
        }

        /// The kept Skills Hub and MCP models for a profile, created on first access without
        /// a request; each screen loads when it opens. Kept as long as the bundle, even after
        /// the host stops listing the profile.
        func profile(_ name: String) -> ProfileModels {
            if let kept = profiles[name] { return kept }
            let models = ProfileModels(profile: name, client: client)
            profiles[name] = models
            return models
        }

        /// Loads the plugins, keeping any rows already shown. The store owns the task, so
        /// opening a section doesn't cancel it; a call while one runs joins it, and a call
        /// once it has finished starts a new one.
        @discardableResult
        func refreshLists() -> Task<Void, Never> {
            if let listRefresh { return listRefresh }
            listGeneration += 1
            let generation = listGeneration
            let task = Task { [weak self, plugins] in
                await plugins.load(force: true)
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
    private let makeClient: (BotConnection, URL) -> DashboardClient

    /// Production clients sign in through the server's shared `HermesConnection`; tests
    /// pass their own.
    init(makeClient: ((BotConnection) -> DashboardClient)? = nil) {
        if let makeClient {
            self.makeClient = { connection, _ in makeClient(connection) }
        } else {
            self.makeClient = { DashboardClient(saved: $0, server: $1) }
        }
    }

    /// For tests that follow which server each client is built for, as production does.
    init(makeServerClient: @escaping (BotConnection, URL) -> DashboardClient) {
        makeClient = makeServerClient
    }

    /// The kept bundle for this server and connection, or a new one that replaces it. A
    /// bundle whose connection was retired (a server switch, or its credentials saved again
    /// or removed) is replaced too, since every call on it now throws `.stale`.
    func bundle(server: URL, connection: BotConnection) -> Bundle {
        let key = Key(server: server.absoluteString, connection: connection)
        if let current, current.key == key, !current.bundle.client.isRetired { return current.bundle }
        dropAll()
        let bundle = Bundle(client: makeClient(connection, server))
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
