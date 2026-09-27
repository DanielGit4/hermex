import CryptoKit
import Foundation

/// The last successful `GET /api/models` and `GET /api/providers` answers, per
/// server and per server-side profile, so pickers and the Providers screen can
/// show rows while the fresh request runs. `APIClient` writes through on every
/// successful fetch and reads it back for its own server and `hermes_profile`
/// cookie, so a leftover can never render under another server or profile.
///
/// Memory sits in front of disk: the first read of a scope after launch loads
/// its file, later reads are memory. Disk I/O runs on the actor, never on the
/// main thread. Providers are written as a projection without `base_url` or
/// `auth_error`, which can carry credentials; models are written as sent.
actor ServerCatalogCache {
    struct Scope: Hashable, Sendable {
        let serverKey: String
        let profileKey: String

        /// `profile` is the client's `hermes_profile` cookie value; nil and empty
        /// both mean "the server's own default", which is its own scope.
        init(server: URL, profile: String?) {
            serverKey = Self.hash(server.absoluteString)
            profileKey = Self.hash(profile ?? "")
        }

        static func hash(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Entry<Value: Sendable>: Sendable {
        let value: Value
        /// When the request that produced this answer started.
        let fetchedAt: Date
    }

    private enum Kind: String {
        case models, providers
    }

    private struct Key: Hashable {
        let scope: Scope
        let kind: Kind
    }

    static let shared = ServerCatalogCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ServerCatalog", isDirectory: true))

    /// A nil directory is an isolated memory cache, used by fixtures.
    let directory: URL?
    private var models: [Scope: Entry<ModelsResponse>] = [:]
    private var providers: [Scope: Entry<ProvidersResponse>] = [:]
    private var readFromDisk: Set<Key> = []
    private var clearedAt: [String: Date] = [:]

    init(directory: URL? = nil) { self.directory = directory }

    func models(for scope: Scope) -> Entry<ModelsResponse>? {
        let key = Key(scope: scope, kind: .models)
        if models[scope] == nil, readFromDisk.insert(key).inserted,
           let entry: Entry<ModelsResponse> = readEntry(key) {
            models[scope] = entry
        }
        return models[scope]
    }

    func providers(for scope: Scope) -> Entry<ProvidersResponse>? {
        let key = Key(scope: scope, kind: .providers)
        if providers[scope] == nil, readFromDisk.insert(key).inserted,
           let entry: Entry<ProvidersResponse> = readEntry(key) {
            providers[scope] = entry
        }
        return providers[scope]
    }

    /// `raw` is the response body exactly as the server sent it.
    func storeModels(_ response: ModelsResponse, raw: Data, scope: Scope, fetchedAt: Date) {
        guard accepts(fetchedAt, scope: scope, current: models[scope]?.fetchedAt) else { return }
        models[scope] = Entry(value: response, fetchedAt: fetchedAt)
        readFromDisk.insert(Key(scope: scope, kind: .models))
        var file = Data(#"{"fetched_at":\#(fetchedAt.timeIntervalSince1970),"response":"#.utf8)
        file.append(raw)
        file.append(Data("}".utf8))
        write(file, for: Key(scope: scope, kind: .models))
    }

    /// Memory keeps the whole answer, including `auth_error`, for this launch.
    func storeProviders(_ response: ProvidersResponse, scope: Scope, fetchedAt: Date) {
        guard accepts(fetchedAt, scope: scope, current: providers[scope]?.fetchedAt) else { return }
        providers[scope] = Entry(value: response, fetchedAt: fetchedAt)
        readFromDisk.insert(Key(scope: scope, kind: .providers))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let envelope = StoredProviders(fetchedAt: fetchedAt.timeIntervalSince1970,
                                       response: ProvidersProjection(response))
        guard let file = try? encoder.encode(envelope) else { return }
        write(file, for: Key(scope: scope, kind: .providers))
    }

    /// Drops every profile's catalogs for `server`, in memory and on disk. A fetch
    /// that started before this call cannot write them back afterwards.
    func remove(server: URL, now: Date = Date()) throws {
        let serverKey = Scope.hash(server.absoluteString)
        clearedAt[serverKey] = now
        models = models.filter { $0.key.serverKey != serverKey }
        providers = providers.filter { $0.key.serverKey != serverKey }
        readFromDisk = readFromDisk.filter { $0.scope.serverKey != serverKey }
        guard let directory else { return }
        let folder = directory.appendingPathComponent(serverKey, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Rejects a fetch that started before a clear, or before the answer already held.
    private func accepts(_ fetchedAt: Date, scope: Scope, current: Date?) -> Bool {
        fetchedAt > (clearedAt[scope.serverKey] ?? .distantPast) && fetchedAt >= (current ?? .distantPast)
    }

    private func fileURL(_ key: Key) -> URL? {
        directory?.appendingPathComponent(key.scope.serverKey, isDirectory: true)
            .appendingPathComponent("\(key.scope.profileKey)-\(key.kind.rawValue).json")
    }

    /// Decodes through the same tolerant models the network path uses.
    private func readEntry<Value: Decodable & Sendable>(_ key: Key) -> Entry<Value>? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let stored = try? decoder.decode(Stored<Value>.self, from: data) else { return nil }
        return Entry(value: stored.response, fetchedAt: Date(timeIntervalSince1970: stored.fetchedAt))
    }

    /// Best effort: a failed write only costs the next launch its instant rows.
    private func write(_ data: Data, for key: Key) {
        guard let url = fileURL(key) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private struct Stored<Response: Decodable>: Decodable {
    let fetchedAt: Double
    let response: Response
}

private struct StoredProviders: Encodable {
    let fetchedAt: Double
    let response: ProvidersProjection
}

/// The fields the Providers screen and Insights read. `base_url` and
/// `auth_error` are left out on purpose: either can embed a credential.
private struct ProvidersProjection: Encodable {
    struct Provider: Encodable {
        let id: String?
        let displayName: String?
        let hasKey: Bool?
        let configurable: Bool?
        let isOauth: Bool?
        let isCustom: Bool?
        let isPluginProvider: Bool?
        let keySource: String?
        let models: [Model]?
        let modelsTotal: Int?
    }

    struct Model: Encodable {
        let id: String?
        let label: String?
    }

    let activeProvider: String?
    let providers: [Provider]?

    init(_ response: ProvidersResponse) {
        activeProvider = response.activeProvider
        providers = response.providers?.map { provider in
            Provider(id: provider.id, displayName: provider.displayName, hasKey: provider.hasKey,
                     configurable: provider.configurable, isOauth: provider.isOauth, isCustom: provider.isCustom,
                     isPluginProvider: provider.isPluginProvider, keySource: provider.keySource,
                     models: provider.models?.map { Model(id: $0.id, label: $0.label) },
                     modelsTotal: provider.modelsTotal)
        }
    }
}
