import Foundation
import Observation

/// The Skills Hub on the user's Hermes host: installed skills, hub search, the review
/// (preview and security scan) an install waits for, and the one install, uninstall or
/// update the host runs at a time. Install, uninstall and update only spawn a process, so
/// success is reported after the action exits 0 and a fresh read shows the change.
@MainActor @Observable final class SkillsHubViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(DashboardProblem)
    }

    enum Operation: Hashable {
        case install(identifier: String, name: String)
        case uninstall(name: String)
        case update
    }

    enum OperationPhase: Equatable {
        case running
        case succeeded(String)
        case failed(String)
    }

    struct OperationState: Equatable {
        let operation: Operation
        var phase: OperationPhase
        /// This run's log lines on the host, newest last.
        var lines: [String] = []
    }

    /// An install shows the preview and the security scan before its button.
    struct Review: Equatable {
        var preview: HubSkillPreview?
        var scan: HubSkillScan?
        var state: LoadState
    }

    struct InstalledSection: Identifiable, Equatable {
        let provenance: String
        let skills: [DashboardSkill]
        var id: String { provenance }
    }

    private(set) var installedSections: [InstalledSection] = []
    private(set) var installedState: LoadState = .idle
    /// Hub lock entries keyed by install identifier: trust level and last scan verdict.
    private(set) var hubLock: [String: HubLockEntry] = [:]
    private(set) var hubLockByName: [String: HubLockEntry] = [:]
    private(set) var results: [HubSkill] = []
    private(set) var searchState: LoadState = .idle
    private(set) var timedOutSources: [String] = []
    private(set) var reviews: [String: Review] = [:]
    private(set) var operation: OperationState?
    /// Why the device-owner check before an uninstall could not run, such as no passcode.
    var authenticationProblem: String?

    private let client: DashboardClient
    private let authenticate: @MainActor (String) async -> DeviceOwnerAuthentication.Outcome
    private let searchDelay: Duration
    private let pollInterval: Duration
    private let maxPolls: Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private var activeQuery = ""
    private var loadedQuery: String?

    /// The main-actor default is built here rather than in a default argument, which Swift
    /// evaluates outside the actor. Delays are injected so tests never sleep.
    init(client: DashboardClient,
         authenticate: (@MainActor (String) async -> DeviceOwnerAuthentication.Outcome)? = nil,
         searchDelay: Duration = .milliseconds(300),
         pollInterval: Duration = .seconds(1),
         maxPolls: Int = 600,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.authenticate = authenticate ?? { await DeviceOwnerAuthentication.confirm(reason: $0) }
        self.searchDelay = searchDelay
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
        self.sleep = sleep
    }

    var isWorking: Bool { operation?.phase == .running }
    func isRunning(_ operation: Operation) -> Bool { isWorking && self.operation?.operation == operation }
    var hasHubSkills: Bool { installedSections.contains { $0.provenance == "hub" } }

    func isInstalled(_ identifier: String) -> Bool { hubLock[identifier] != nil }

    // MARK: - Installed

    /// The installed list renders as soon as it arrives; hub trust levels fill in after,
    /// because the lock comes from the slower hub sources route and is optional.
    func loadInstalled() async {
        guard installedState != .loading else { return }
        installedState = .loading
        async let lock = lockEntries()
        do {
            setInstalled(try await client.installedSkills())
            installedState = .loaded
        } catch {
            installedState = DashboardProblem.isCancellation(error)
                ? (installedSections.isEmpty ? .idle : .loaded) : .failed(DashboardProblem(error))
        }
        if let entries = await lock { setHubLock(entries) }
    }

    // MARK: - Search

    /// Called from `.task(id:)` on every query change, which cancels the previous call, so
    /// only a query left alone for `searchDelay` reaches the host. An empty query never does.
    func search(_ rawQuery: String, force: Bool = false) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = query
        guard !query.isEmpty else {
            results = []
            timedOutSources = []
            searchState = .idle
            loadedQuery = nil
            return
        }
        // Returning from a result re-runs the task with the same query; the results stand.
        guard force || query != loadedQuery else { return }
        do { try await sleep(searchDelay) } catch { return }
        guard !Task.isCancelled, activeQuery == query else { return }
        searchState = .loading
        do {
            let found = try await client.searchHub(query)
            guard !Task.isCancelled, activeQuery == query else { return }
            results = found.results
            timedOutSources = found.timedOut
            if let installed = found.installed { setHubLock(installed) }
            loadedQuery = query
            searchState = .loaded
        } catch {
            guard !Task.isCancelled, activeQuery == query, !DashboardProblem.isCancellation(error) else { return }
            searchState = .failed(DashboardProblem(error))
        }
    }

    // MARK: - Review

    func review(_ identifier: String, force: Bool = false) async {
        if let existing = reviews[identifier] {
            guard existing.state != .loading, force || existing.state != .loaded else { return }
        }
        reviews[identifier] = Review(state: .loading)
        do {
            async let preview = client.previewHubSkill(identifier)
            async let scan = client.scanHubSkill(identifier)
            let (loadedPreview, loadedScan) = try await (preview, scan)
            reviews[identifier] = Review(preview: loadedPreview, scan: loadedScan, state: .loaded)
        } catch {
            reviews[identifier] = DashboardProblem.isCancellation(error)
                ? nil : Review(state: .failed(DashboardProblem(error)))
        }
    }

    /// Only after the preview and the scan are both on screen, the scan's policy lets the
    /// host install it, and it is not installed already.
    func canInstall(_ identifier: String) -> Bool {
        guard let review = reviews[identifier], review.state == .loaded, review.preview != nil,
              let scan = review.scan, scan.allowsInstall else { return false }
        return !isInstalled(identifier) && !isWorking
    }

    // MARK: - Operations

    func install(_ identifier: String) async {
        guard canInstall(identifier), let name = reviews[identifier]?.preview?.skill.name else { return }
        await run(.install(identifier: identifier, name: name), spawn: { try await $0.installHubSkill(identifier) }) {
            let skills = try await self.refreshInstalled()
            // A blocked install still exits 0, so the lock (or the listing) must show it.
            return self.hubLock[identifier] != nil || skills.contains { $0.isFromHub && $0.name == name }
        }
    }

    /// Asks for Face ID or the passcode first: this permanently removes the skill from the host.
    func uninstall(_ name: String) async {
        guard !isWorking, !name.isEmpty else { return }
        authenticationProblem = nil
        switch await authenticate(String(localized: "Confirm removing “\(name)” from your Hermes host.")) {
        case .confirmed: break
        case .cancelled: return
        case .unavailable(let message):
            authenticationProblem = message
            return
        }
        await run(.uninstall(name: name), spawn: { try await $0.uninstallHubSkill(name) }) {
            let skills = try await self.refreshInstalled()
            return !skills.contains { $0.isFromHub && $0.name == name }
        }
    }

    /// The host's global `hermes skills update`: the contract has no per-skill update
    /// signal, so this is one action, and it re-scans each new version before replacing.
    func update() async {
        guard !isWorking, hasHubSkills else { return }
        await run(.update, spawn: { try await $0.updateHubSkills() }) {
            _ = try? await self.refreshInstalled()
            return true
        }
    }

    func dismissOperationResult() {
        guard !isWorking else { return }
        operation = nil
    }

    private func run(_ operation: Operation, spawn: (DashboardClient) async throws -> String,
                     confirm: () async throws -> Bool) async {
        guard !isWorking else { return }
        self.operation = OperationState(operation: operation, phase: .running)
        var started = false
        do {
            let action = try await spawn(client)
            started = true
            guard let status = try await poll(action) else {
                return finish(.failed(String(localized: "Hermes is still working on this. Refresh later to see how it ended.")))
            }
            guard let exitCode = status.exitCode else {
                return finish(.failed(String(localized: "Hermes couldn’t report how this ended. Refresh to check.")))
            }
            guard exitCode == 0 else {
                return finish(.failed(String(localized: "Hermes reported a failure (exit code \(exitCode)).")))
            }
            guard try await confirm() else { return finish(.failed(Self.unconfirmedMessage(operation))) }
            finish(.succeeded(Self.successMessage(operation)))
        } catch {
            finish(.failed(started
                ? String(localized: "Lost contact with your Hermes host while it was working. It may still finish; refresh to check.")
                : DashboardProblem(error).message))
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

    private func finish(_ phase: OperationPhase) {
        operation?.phase = phase
    }

    private static func successMessage(_ operation: Operation) -> String {
        switch operation {
        case .install(_, let name): return String(localized: "Installed “\(name)” on your Hermes host.")
        case .uninstall(let name): return String(localized: "Removed “\(name)” from your Hermes host.")
        case .update: return String(localized: "Hermes finished updating hub skills.")
        }
    }

    private static func unconfirmedMessage(_ operation: Operation) -> String {
        switch operation {
        case .install(_, let name):
            return String(localized: "Hermes finished, but “\(name)” isn’t installed. The host may have refused it.")
        case .uninstall(let name):
            return String(localized: "Hermes finished, but “\(name)” is still installed.")
        case .update:
            // An update has nothing to re-read: its exit code is the host's answer.
            return successMessage(operation)
        }
    }

    // MARK: - State

    @discardableResult
    private func refreshInstalled() async throws -> [DashboardSkill] {
        async let lock = lockEntries()
        let skills = try await client.installedSkills()
        setInstalled(skills)
        installedState = .loaded
        if let entries = await lock { setHubLock(entries) }
        return skills
    }

    private func lockEntries() async -> [String: HubLockEntry]? {
        try? await client.hubLock()
    }

    private func setInstalled(_ skills: [DashboardSkill]) {
        let grouped = Dictionary(grouping: skills) { $0.provenance ?? "" }
        let order = ["hub", "bundled", "agent"]
        installedSections = grouped.keys
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs) ?? order.count, right = order.firstIndex(of: rhs) ?? order.count
                return left == right ? lhs < rhs : left < right
            }
            .map { key in
                InstalledSection(provenance: key, skills: (grouped[key] ?? []).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                })
            }
    }

    private func setHubLock(_ entries: [String: HubLockEntry]) {
        hubLock = entries
        hubLockByName = entries.values.reduce(into: [:]) { byName, entry in
            if let name = entry.name { byName[name] = entry }
        }
    }
}
