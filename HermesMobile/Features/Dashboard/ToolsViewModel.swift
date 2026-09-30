import Foundation
import Observation

/// The profiles on the user's Hermes host, each with how many of its toolsets are on. It owns
/// one `ProfileToolsViewModel` per profile, so the counts here and the profile's Tools screen
/// read the same rows, and a toggle there updates its count here without another request.
@MainActor @Observable final class ToolsProfilesViewModel {
    struct ProfileSummary: Identifiable {
        let tools: ProfileToolsViewModel
        let name: String
        /// Nil until the profile's toolsets have loaded once.
        let enabledCount: Int?
        let totalCount: Int?
        var id: String { name }
    }

    private(set) var listState: DashboardLoadState = .idle
    /// When the profile names on screen were read from the host.
    private(set) var lastLoadedAt: Date?
    /// In the host's order, each kept while the host still lists its profile.
    private var profileModels: [ProfileToolsViewModel] = []

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    var profiles: [ProfileSummary] {
        profileModels.map { tools in
            let loaded = tools.lastLoadedAt != nil
            return ProfileSummary(tools: tools, name: tools.profile, enabledCount: loaded ? tools.enabledCount : nil,
                                  totalCount: loaded ? tools.totalCount : nil)
        }
    }

    /// The host's only profile, whose toolsets show without a list to pick from.
    var soleProfile: ProfileToolsViewModel? { profileModels.count == 1 ? profileModels.first : nil }

    func tools(for profile: String) -> ProfileToolsViewModel? { profileModels.first { $0.profile == profile } }

    /// Reads the profile names, then every profile's toolsets side by side for the counts.
    /// One profile failing leaves only its counts unknown. Without `force`, only profiles
    /// whose toolsets haven't loaded are read.
    func load(force: Bool = false) async {
        guard listState != .loading else { return }
        if force || listState != .loaded {
            listState = .loading
            do {
                let startedAt = Date()
                let names = try await client.profileNames()
                profileModels = names.map { name in tools(for: name) ?? ProfileToolsViewModel(client: client, profile: name) }
                lastLoadedAt = startedAt
                listState = .loaded
            } catch {
                listState = DashboardProblem.isCancellation(error)
                    ? (profileModels.isEmpty ? .idle : .loaded) : .failed(DashboardProblem(error))
                return
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for tools in profileModels {
                group.addTask { await tools.load(force: force) }
            }
        }
    }
}

/// One profile's toolsets on the host. A toggle is optimistic: the row flips at once, rolls
/// back with the host's reason if the change fails, and either way the rows are read again.
@MainActor @Observable final class ProfileToolsViewModel {
    /// The rows of one platform, in the host's order. `cli` rows come first, untitled; a
    /// toolset the host limits to another platform, such as Discord, is titled by it.
    struct ToolsetSection: Identifiable, Equatable {
        let platform: String
        let title: String?
        let toolsets: [DashboardToolset]
        var id: String { platform }
    }

    static let cliPlatform = "cli"
    static var guardMessage: String { String(localized: "Keep at least one tool on.") }

    let profile: String
    private(set) var toolsets: [DashboardToolset] = []
    private(set) var listState: DashboardLoadState = .idle
    /// When the rows on screen were read from the host.
    private(set) var lastLoadedAt: Date?
    /// The value each running toggle asked for, which its row already shows.
    private(set) var pendingToggles: [String: Bool] = [:]
    private(set) var toggleProblems: [String: String] = [:]
    /// The toolset whose enabling started an install on the host, until the next toggle or
    /// leaving the screen.
    private(set) var installNotice: String?
    /// Set when turning off the last `cli` toolset was refused.
    private(set) var guardNotice: String?

    private let client: DashboardClient
    /// The newest read. Rows come only from it, so an older answer landing late never wins.
    private var generation = 0
    /// Owned here rather than by a screen, so leaving a screen never cancels a read another
    /// screen is waiting on.
    private var reading: Task<Void, Never>?

    init(client: DashboardClient, profile: String) {
        self.client = client
        self.profile = profile
    }

    func toolset(named name: String) -> DashboardToolset? { toolsets.first { $0.name == name } }

    var enabledCount: Int { toolsets.filter(\.enabled).count }
    var totalCount: Int { toolsets.count }

    var sections: [ToolsetSection] {
        var platforms: [String] = []
        var rows: [String: [DashboardToolset]] = [:]
        for toolset in toolsets {
            if rows[toolset.platform] == nil { platforms.append(toolset.platform) }
            rows[toolset.platform, default: []].append(toolset)
        }
        let ordered = platforms.filter { $0 == Self.cliPlatform } + platforms.filter { $0 != Self.cliPlatform }
        return ordered.map { platform in
            let toolsets = rows[platform] ?? []
            let title = platform == Self.cliPlatform
                ? nil : String(localized: "\(toolsets.first?.platformLabel ?? platform) only")
            return ToolsetSection(platform: platform, title: title, toolsets: toolsets)
        }
    }

    /// False only for the last enabled `cli` toolset, pending values included. Toolsets
    /// limited to another platform never count toward it and are never held by it.
    func canTurnOff(_ name: String) -> Bool {
        guard let toolset = toolset(named: name), toolset.enabled, toolset.platform == Self.cliPlatform else { return true }
        return toolsets.contains { $0.name != name && $0.enabled && $0.platform == Self.cliPlatform }
    }

    // MARK: - List

    /// A read already running is joined unless `force` asks for a newer one.
    func load(force: Bool = false) async {
        if !force, let reading { return await reading.value }
        guard force || listState != .loaded else { return }
        listState = .loading
        await read().value
    }

    private func read() -> Task<Void, Never> {
        generation += 1
        let current = generation
        let task = Task {
            let startedAt = Date()
            do {
                let fresh = try await client.toolsets(profile: profile)
                guard current == generation else { return }
                // A row whose toggle is running keeps the value asked for until the host answers it.
                toolsets = fresh.map { row in
                    var row = row
                    row.enabled = pendingToggles[row.name] ?? row.enabled
                    return row
                }
                lastLoadedAt = startedAt
                listState = .loaded
            } catch {
                guard current == generation else { return }
                listState = DashboardProblem.isCancellation(error)
                    ? (toolsets.isEmpty ? .idle : .loaded) : .failed(DashboardProblem(error))
            }
            reading = nil
        }
        reading = task
        return task
    }

    // MARK: - Enable and disable

    /// Applies the host's saved value, or rolls back with its reason; then reads the rows again.
    func setEnabled(_ name: String, to enabled: Bool) async {
        guard pendingToggles[name] == nil, let previous = toolset(named: name)?.enabled, previous != enabled else { return }
        guard enabled || canTurnOff(name) else {
            guardNotice = Self.guardMessage
            return
        }
        guardNotice = nil
        installNotice = nil
        toggleProblems[name] = nil
        pendingToggles[name] = enabled
        setRow(name, enabled: enabled)
        do {
            let result = try await client.setToolset(name, enabled: enabled, profile: profile)
            pendingToggles[name] = nil
            setRow(name, enabled: result.enabled)
            if result.postSetupStarted != nil { installNotice = name }
        } catch {
            pendingToggles[name] = nil
            setRow(name, enabled: previous)
            if !DashboardProblem.isCancellation(error) { toggleProblems[name] = DashboardProblem(error).message }
        }
        await read().value
    }

    /// Notes that only make sense on screen: the install note and the guard's refusal.
    func clearNotices() {
        installNotice = nil
        guardNotice = nil
    }

    private func setRow(_ name: String, enabled: Bool) {
        guard let index = toolsets.firstIndex(where: { $0.name == name }) else { return }
        toolsets[index].enabled = enabled
    }
}
