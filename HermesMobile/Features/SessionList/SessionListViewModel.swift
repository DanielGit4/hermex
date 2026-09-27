import Foundation
import Observation
import SwiftData
import SwiftUI

struct SessionListSection: Identifiable {
    enum Kind: String {
        case pinned
        case today
        case yesterday
        case earlier
    }

    let kind: Kind
    let title: String
    let sessions: [SessionSummary]

    var id: String { kind.rawValue }
}

/// One messaging platform's rows, shown as a disclosure below Scheduled.
struct MessagingSessionGroup: Identifiable, Equatable {
    let platform: String
    let sessions: [SessionSummary]
    /// The platform's rows without the search query, for the disclosure badge.
    let totalCount: Int

    var id: String { platform }
    var title: String { SessionSource.label(for: platform) }
}

/// The list's rows split into its sections: Scheduled, one disclosure per
/// messaging platform, and the ordinary Sessions rows.
struct SessionListGroups: Equatable {
    let ordinary: [SessionSummary]
    let scheduled: [SessionSummary]
    /// Platforms with at least one visible row, in label order so a new
    /// message never moves a disclosure.
    let messaging: [MessagingSessionGroup]
    let totalScheduledCount: Int

    /// Splits the visible rows in one pass, keeping their order: cron rows go
    /// to `scheduled` unless archived, messaging rows to their platform, and
    /// everything else to `ordinary`. `messagingTotals` defaults to the group
    /// sizes, which is right whenever no search narrows the rows.
    init(
        partitioning visible: [SessionSummary],
        totalScheduledCount: Int,
        messagingTotals: [String: Int]? = nil
    ) {
        var ordinary: [SessionSummary] = []
        var scheduled: [SessionSummary] = []
        var messagingRows: [String: [SessionSummary]] = [:]
        for session in visible {
            if session.isCronSession {
                if session.archived != true { scheduled.append(session) }
            } else if let platform = session.messagingPlatform {
                messagingRows[platform, default: []].append(session)
            } else {
                ordinary.append(session)
            }
        }
        self.ordinary = ordinary
        self.scheduled = scheduled
        self.messaging = messagingRows
            .map { platform, rows in
                MessagingSessionGroup(
                    platform: platform,
                    sessions: rows,
                    totalCount: messagingTotals?[platform] ?? rows.count
                )
            }
            .sorted { left, right in
                switch left.title.localizedStandardCompare(right.title) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return left.platform < right.platform
                }
            }
        self.totalScheduledCount = totalScheduledCount
    }

    var scheduledPreview: [SessionSummary] {
        Array(scheduled.prefix(5))
    }

    var hasAdditionalScheduledSessions: Bool {
        scheduled.count > scheduledPreview.count
    }

    func showsDisclosure(isSearchActive: Bool) -> Bool {
        totalScheduledCount > 0 && (!isSearchActive || !scheduled.isEmpty)
    }
}

enum ActiveSessionStateRefreshResult: Equatable {
    case unchanged
    case reloaded
    case failed
}

@MainActor
@Observable
final class SessionListViewModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var isCreatingSession = false
    private(set) var isCreatingProject = false
    private(set) var isLoadingProjects = false
    private(set) var isDeletingProject = false
    private(set) var isRenamingSession = false
    private(set) var isRenamingProject = false
    private(set) var isMovingSession = false
    private(set) var isViewingCachedData = false
    private(set) var projects: [ProjectSummary] = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var cacheErrorMessage: String?
    private(set) var searchErrorMessage: String?
    private(set) var isSearchingRemoteSessions = false
    private(set) var sessionLoadError: Error?
    private(set) var lastError: Error?
    private(set) var activeProfileName: String?
    private(set) var activeProfileDisplayName: String?
    private(set) var activeProfileModel: String?
    private(set) var activeProfileProvider: String?
    private(set) var profileOptions: [ProfileSummary] = []
    /// The profile this client's server cookie (`hermes_profile`) selects, as
    /// last reported. `activeProfileName` is the user's pick, which New Chat
    /// uses; the two differ after a row from another profile was opened.
    private(set) var serverProfileName: String?
    /// False when the last live load listed only the active profile (an
    /// isolated-profile server, or one older than `all_profiles`); nil before
    /// any live load, so cached rows still show their profiles.
    private(set) var listsAllProfiles: Bool?
    private(set) var isSingleProfileMode = false
    private(set) var isLoadingActiveProfile = false
    private(set) var isSwitchingActiveProfile = false
    private(set) var switchingActiveProfileName: String?
    private(set) var activeProfileErrorMessage: String?
    private(set) var mutatingSessionIDs: Set<String> = []
    /// Total archived sessions reported by the last successful list load
    /// (`archived_count`, issue #17). nil until a load succeeds or when an older
    /// server omits the field — the Archived entry stays hidden then.
    private(set) var archivedCount: Int?

    /// Attention state per streaming session, refreshed on the same tick that
    /// already checks stream liveness. Only sessions with an active stream ever
    /// have an entry, and the map is reassigned only when a value actually
    /// changes so rows do not invalidate on every poll tick.
    private(set) var attentionStatesBySessionID: [String: SessionRowAttentionState] = [:]
    private(set) var seenMessageTimes: [String: Double]

    private(set) var remoteContentSearchSessionIDs: [String] = []
    /// `match_preview` per content-matched session from the last search, so a
    /// row can show why it matched. Empty against servers that omit the field.
    private(set) var remoteContentSearchExcerpts: [String: String] = [:]
    private var activeRemoteSearchQuery: String?
    private var sessionOpenGeneration = 0
    /// The profile the list moved the server to, away from the pick, to reach
    /// a row. A profile reload that still finds the server there keeps the pick.
    private var profileMovedForRow: String?
    /// Set while a switch is in flight or after one ended without an answer,
    /// so the next row re-sends it instead of trusting `serverProfileName`.
    private var serverProfileIsUncertain = false

    private let client: APIClient
    private let sessionMutator: SessionMutator
    private let server: URL
    private let unreadStore: SessionUnreadStore
    private var viewingSessionID: String?
    private var returnedFromSessionIDs: Set<String> = []
    private var firstReturnLoad: (revision: Int, sessionIDs: Set<String>)?
    private var returnRevision = 0
    private var activeLoadCount = 0

    init(server: URL, client: APIClient? = nil, unreadStore: SessionUnreadStore = SessionUnreadStore()) {
        self.server = server
        self.unreadStore = unreadStore
        seenMessageTimes = unreadStore.load(for: server)
        let resolvedClient = client ?? APIClient(baseURL: server)
        self.client = resolvedClient
        self.sessionMutator = SessionMutator(client: resolvedClient)

        // Sweep exports leaked by a previous app run (view dismissed while a
        // download was in flight, so the share sheet — and its on-dismiss
        // cleanup — never appeared). `State(initialValue:)` re-runs this init
        // on every parent redraw, so the sweep must be once-per-process (the
        // lazy static below), or it would delete a file an active share sheet
        // is presenting. The first-ever init always precedes the first export,
        // so the single sweep can never race an in-flight export.
        _ = Self.sweepLeakedExportsOnce
    }

    /// Root temp directory holding one UUID subdirectory per export
    /// (see `export(_:format:)`).
    nonisolated static var exportsRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-exports", isDirectory: true)
    }

    /// Lazy static ⇒ runs exactly once per process, on first access.
    nonisolated private static let sweepLeakedExportsOnce: Void = {
        try? FileManager.default.removeItem(at: exportsRootDirectory)
    }()

    var sections: [SessionListSection] {
        let sortedSessions = sessions.sorted { left, right in
            timestamp(for: left) > timestamp(for: right)
        }
        let pinned = sortedSessions.filter { $0.pinned == true }
        let unpinned = sortedSessions.filter { $0.pinned != true }

        let calendar = Calendar.current
        let today = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInToday(date)
        }
        let yesterday = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInYesterday(date)
        }
        let earlier = unpinned.filter { session in
            guard let date = date(for: session) else { return true }
            return !calendar.isDateInToday(date) && !calendar.isDateInYesterday(date)
        }

        return [
            SessionListSection(kind: .pinned, title: String(localized: "Pinned"), sessions: pinned),
            SessionListSection(kind: .today, title: String(localized: "Today"), sessions: today),
            SessionListSection(kind: .yesterday, title: String(localized: "Yesterday"), sessions: yesterday),
            SessionListSection(kind: .earlier, title: String(localized: "Earlier"), sessions: earlier)
        ]
        .filter { !$0.sessions.isEmpty }
    }

    /// The rows the list shows for this search, project filter, automated
    /// visibility, and profile filter (nil shows every profile): local matches
    /// sorted, then loaded remote content matches.
    func visibleSessions(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll,
        profileFilter: String? = nil
    ) -> [SessionSummary] {
        visibleSessions(
            among: sessions,
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility,
            profileFilter: profileFilter
        )
    }

    /// The visible rows that are still streaming, for the list's active-row
    /// monitor. Filters to streaming rows first (usually zero to two), so a
    /// body pass does not filter and sort every session to find them.
    func visibleActiveSessions(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll,
        profileFilter: String? = nil
    ) -> [SessionSummary] {
        let activeSessions = sessions.filter(SessionRowView.isActiveStreaming)
        guard !activeSessions.isEmpty else { return [] }
        return visibleSessions(
            among: activeSessions,
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility,
            profileFilter: profileFilter
        )
    }

    /// Visibility is decided per row, so running this over a subset of
    /// `sessions` yields exactly the visible rows of that subset.
    private func visibleSessions(
        among candidates: [SessionSummary],
        searchText rawSearchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility,
        profileFilter: String?
    ) -> [SessionSummary] {
        let query = Self.normalizedSearchQuery(rawSearchText)
        let projectFilteredSessions = filteredSessions(
            among: candidates,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility,
            profileFilter: profileFilter
        )
        let localMatches = projectFilteredSessions.filter { session in
            guard !query.isEmpty else { return true }
            return Self.searchableText(for: session).contains(query)
        }
        let sortedLocalMatches = Self.sortedSessions(localMatches)

        guard !query.isEmpty, activeRemoteSearchQuery == query else {
            return sortedLocalMatches
        }

        let localMatchIDs = Set(sortedLocalMatches.compactMap(\.sessionId))
        let sessionsByID = Dictionary(
            projectFilteredSessions.compactMap { session -> (String, SessionSummary)? in
                guard let sessionID = session.sessionId, !sessionID.isEmpty else { return nil }
                return (sessionID, session)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMatches = remoteContentSearchSessionIDs.compactMap { sessionID -> SessionSummary? in
            guard !localMatchIDs.contains(sessionID) else { return nil }
            return sessionsByID[sessionID]
        }

        return sortedLocalMatches + Self.sortedSessions(remoteMatches)
    }

    /// Every filter but the search query, in one pass.
    private func filteredSessions(
        among candidates: [SessionSummary],
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility,
        profileFilter: String?
    ) -> [SessionSummary] {
        candidates.filter { session in
            automatedVisibility.shows(session)
                && (selectedProjectID == nil || session.projectId == selectedProjectID)
                && matchesProfileFilter(session, profileFilter)
        }
    }

    /// The visible rows split into Scheduled, per-platform messaging, and
    /// ordinary rows. The Scheduled badge counts every non-archived cron row
    /// of the filtered profiles (#125: not narrowed by project or search); a
    /// messaging badge counts its platform's rows without the search query.
    func sessionListGroups(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll,
        profileFilter: String? = nil
    ) -> SessionListGroups {
        let visible = visibleSessions(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility,
            profileFilter: profileFilter
        )
        var messagingTotals: [String: Int]?
        if !Self.normalizedSearchQuery(searchText).isEmpty {
            var totals: [String: Int] = [:]
            for session in filteredSessions(
                among: sessions,
                selectedProjectID: selectedProjectID,
                automatedVisibility: automatedVisibility,
                profileFilter: profileFilter
            ) where !session.isCronSession {
                if let platform = session.messagingPlatform { totals[platform, default: 0] += 1 }
            }
            messagingTotals = totals
        }

        return SessionListGroups(
            partitioning: visible,
            totalScheduledCount: automatedVisibility.showsCron
                ? sessions.filter {
                    $0.isCronSession && $0.archived != true && matchesProfileFilter($0, profileFilter)
                }.count
                : 0,
            messagingTotals: messagingTotals
        )
    }

    // MARK: - Profiles in the list

    /// The server's default profile: the one flagged `is_default`, else `default`.
    var defaultProfileName: String {
        profileOptions.first { $0.isDefault == true }?.normalizedName ?? "default"
    }

    /// Whether rows may come from more than one profile, so they name theirs.
    /// False in single-profile mode and when the server listed only the
    /// active profile.
    var showsRowProfiles: Bool {
        !isSingleProfileMode && listsAllProfiles != false
    }

    /// The profile a row belongs to; rows that name none belong to the default.
    func profileName(of session: SessionSummary) -> String {
        Self.nonEmpty(session.profile) ?? defaultProfileName
    }

    /// How the profile filter names a profile: `default` reads "Default".
    func profileDisplayName(_ name: String) -> String {
        profileOptions.first { $0.normalizedName == name }?.displayName
            ?? (name == "default" ? String(localized: "Default") : name)
    }

    /// The row's profile chip: its profile's name, only for a profile other
    /// than the default while rows can come from several profiles.
    func profileChipLabel(for session: SessionSummary) -> String? {
        guard showsRowProfiles,
              let profile = Self.nonEmpty(session.profile),
              profile != defaultProfileName
        else { return nil }
        return profile
    }

    /// The profiles the list can be narrowed to, empty when there is nothing
    /// to choose between. Offline, before the profile list loads, the cached
    /// rows' own profiles stand in.
    var profileFilterOptions: [String] {
        guard showsRowProfiles else { return [] }
        var names = profileOptions.compactMap(\.normalizedName)
        if names.isEmpty {
            var seen = Set<String>()
            names = sessions.map(profileName(of:)).filter { seen.insert($0).inserted }.sorted()
        }
        return names.count > 1 ? names : []
    }

    /// `stored` when it still names a filterable profile, else nil (all
    /// profiles), so a filter for a removed profile never empties the list.
    func effectiveProfileFilter(_ stored: String?) -> String? {
        guard let stored = Self.nonEmpty(stored), profileFilterOptions.contains(stored) else { return nil }
        return stored
    }

    /// The projects the Projects section lists under `profileFilter`.
    func visibleProjects(profileFilter: String?) -> [ProjectSummary] {
        guard let profileFilter else { return projects }
        return projects.filter { (Self.nonEmpty($0.profile) ?? defaultProfileName) == profileFilter }
    }

    /// The count a Projects row shows: its sessions the list would show.
    func sessionCount(
        inProject project: ProjectSummary,
        automatedVisibility: AutomatedSessionVisibility,
        profileFilter: String?
    ) -> Int {
        guard let projectID = project.projectId else { return 0 }
        return sessions.filter { session in
            session.projectId == projectID
                && automatedVisibility.shows(session)
                && matchesProfileFilter(session, profileFilter)
        }.count
    }

    /// The projects `session` can move into: its own profile's.
    func moveTargets(for session: SessionSummary) -> [ProjectSummary] {
        visibleProjects(profileFilter: showsRowProfiles ? profileName(of: session) : nil)
    }

    private func matchesProfileFilter(_ session: SessionSummary, _ profileFilter: String?) -> Bool {
        guard let profileFilter else { return true }
        return profileName(of: session) == profileFilter
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil, animation: Animation? = nil) async -> Bool {
        // Overlapping requests for the same return share its mark. A later
        // return starts a new window, even if the prior load is still in flight.
        let revision = returnRevision
        let firstReturnedIDs = returnedFromSessionIDs
        let inFlightIDs = firstReturnLoad?.revision == revision ? firstReturnLoad?.sessionIDs ?? [] : []
        let returnedFromIDs = firstReturnedIDs.union(inFlightIDs)
        returnedFromSessionIDs.removeAll()
        if !firstReturnedIDs.isEmpty {
            firstReturnLoad = (revision, firstReturnedIDs)
        }
        activeLoadCount += 1
        isLoading = true
        errorMessage = nil
        cacheErrorMessage = nil
        sessionLoadError = nil
        lastError = nil
        defer {
            if !firstReturnedIDs.isEmpty && firstReturnLoad?.revision == revision {
                firstReturnLoad = nil
            }
            activeLoadCount -= 1
            isLoading = activeLoadCount > 0
        }

        do {
            let response = try await client.sessionList()
            guard revision == returnRevision else { return false }
            listsAllProfiles = response.allProfiles ?? false
            if let serverProfile = Self.nonEmpty(response.activeProfile) {
                serverProfileName = serverProfile
                serverProfileIsUncertain = false
            }
            let allSessions = response.sessions ?? []
            let visibleSessions = allSessions
                .filter {
                    Self.nonEmpty($0.sessionId) != nil
                        && $0.archived != true
                        && $0.shouldAppearInSessionList
                }
            reconcileUnread(visibleSessions, allSessions: allSessions, returnedFromIDs: returnedFromIDs)
            applySessions(visibleSessions, archivedCount: response.archivedCount, animation: animation)
            isViewingCachedData = false

            if let modelContext {
                do {
                    try CacheStore.cacheSessions(visibleSessions, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return true
        } catch {
            guard !isCancellationError(error) else { return false }
            guard revision == returnRevision else { return false }

            lastError = error
            sessionLoadError = error
            if CacheFallbackPolicy.shouldUseCache(for: error), let modelContext {
                do {
                    let cachedSessions = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                        .filter(\.shouldAppearInSessionList)
                    if !cachedSessions.isEmpty {
                        sessions = cachedSessions
                        isViewingCachedData = true
                        errorMessage = nil
                        // Cached rows carry no live server state, so nothing can
                        // still be waiting on the user here.
                        clearAttentionStates()
                    } else {
                        isViewingCachedData = false
                        errorMessage = error.localizedDescription
                    }
                } catch {
                    cacheErrorMessage = error.localizedDescription
                    isViewingCachedData = false
                    errorMessage = lastError?.localizedDescription
                }
            } else {
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }

            return false
        }
    }

    func loadActiveProfile() async {
        guard !isLoadingActiveProfile else { return }

        isLoadingActiveProfile = true
        activeProfileErrorMessage = nil
        defer { isLoadingActiveProfile = false }

        do {
            let response = try await client.profiles()
            applyActiveProfile(response)
        } catch {
            guard !isCancellationError(error) else { return }

            activeProfileErrorMessage = error.localizedDescription
        }
    }

    func switchActiveProfile(_ profile: ProfileSummary) async -> Bool {
        guard !isViewingCachedData else {
            activeProfileErrorMessage = String(localized: "Reconnect to the server to change profiles.")
            return false
        }

        guard let profileName = Self.nonEmpty(profile.name) else {
            activeProfileErrorMessage = String(localized: "The server did not provide a profile name.")
            return false
        }

        guard profileName != activeProfileName else {
            return true
        }

        isSwitchingActiveProfile = true
        switchingActiveProfileName = profileName
        activeProfileErrorMessage = nil
        lastError = nil
        defer {
            isSwitchingActiveProfile = false
            switchingActiveProfileName = nil
        }

        do {
            let response = try await client.switchProfile(name: profileName)
            if let error = Self.nonEmpty(response.error) {
                activeProfileErrorMessage = error
                return false
            }

            let resolvedName = Self.nonEmpty(response.active) ?? profileName
            // A pick is never a move for a row, even onto the profile a row moved to.
            profileMovedForRow = nil
            // The switch response has no `single_profile_mode` field; carry the
            // last known value forward so the switcher visibility doesn't flap.
            let profileResponse = ProfilesResponse(
                profiles: response.profiles ?? profileOptions,
                active: resolvedName,
                singleProfileMode: isSingleProfileMode
            )
            applyActiveProfile(
                profileResponse,
                fallbackProfile: profile,
                fallbackDefaultModel: response.defaultModel
            )
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            activeProfileErrorMessage = error.localizedDescription
            return false
        }
    }

    func searchSessions(
        query rawQuery: String,
        content: Bool = true,
        depth: Int = 5,
        debounceNanoseconds: UInt64 = 350_000_000
    ) async {
        let query = Self.normalizedSearchQuery(rawQuery)
        activeRemoteSearchQuery = query
        remoteContentSearchSessionIDs = []
        remoteContentSearchExcerpts = [:]
        searchErrorMessage = nil

        guard !query.isEmpty, !isViewingCachedData else {
            isSearchingRemoteSessions = false
            return
        }

        do {
            if debounceNanoseconds > 0 {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            }

            guard !Task.isCancelled, activeRemoteSearchQuery == query else { return }

            isSearchingRemoteSessions = true
            let response = try await client.searchSessions(
                query: query,
                content: content,
                depth: depth,
                allProfiles: true
            )

            guard !Task.isCancelled, activeRemoteSearchQuery == query else { return }

            let matches = contentMatches(from: response.sessions ?? [])
            remoteContentSearchSessionIDs = matches.sessionIDs
            remoteContentSearchExcerpts = matches.excerpts
            isSearchingRemoteSessions = false
        } catch {
            guard activeRemoteSearchQuery == query else { return }

            isSearchingRemoteSessions = false
            guard !isCancellationError(error) else { return }

            remoteContentSearchSessionIDs = []
            remoteContentSearchExcerpts = [:]
            searchErrorMessage = error.localizedDescription
            lastError = error
        }
    }

    /// The excerpt to show under a row, paired with the query that produced it.
    /// nil when the row did not match on content, when the search was cleared,
    /// or when the server is older than `match_preview`.
    ///
    /// `searchText` is the query of the *screen* asking, not the view model's:
    /// screens with their own search field (Scheduled sessions) share this view
    /// model, and they must not inherit the sidebar's last excerpts. Same guard
    /// `visibleSessions(searchText:selectedProjectID:)` applies to remote rows.
    func searchExcerpt(for session: SessionSummary, searchText: String) -> SessionSearchExcerpt? {
        let query = Self.normalizedSearchQuery(searchText)

        guard !query.isEmpty, activeRemoteSearchQuery == query,
              let sessionID = session.sessionId,
              let text = remoteContentSearchExcerpts[sessionID]
        else {
            return nil
        }

        return SessionSearchExcerpt(text: text, query: query)
    }

    func clearSearchResults() {
        activeRemoteSearchQuery = nil
        remoteContentSearchSessionIDs = []
        remoteContentSearchExcerpts = [:]
        searchErrorMessage = nil
        isSearchingRemoteSessions = false
    }

    private var loadFailureRefreshResult: ActiveSessionStateRefreshResult {
        lastError == nil ? .unchanged : .failed
    }

    @discardableResult
    func refreshActiveSessionStatesIfNeeded(
        streamIDs rawStreamIDs: [String],
        modelContext: ModelContext? = nil
    ) async -> ActiveSessionStateRefreshResult {
        guard !isViewingCachedData, !isLoading else { return .unchanged }

        let streamIDs = Self.normalizedStreamIDs(rawStreamIDs)
        guard !streamIDs.isEmpty else {
            return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
        }

        for streamID in streamIDs {
            do {
                let response = try await client.chatStreamStatus(streamID: streamID)
                guard response.active == false else { continue }
                return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
            } catch {
                guard !isCancellationError(error) else { return .unchanged }
                if case APIError.unauthorized = error {
                    lastError = error
                    return .failed
                }
                continue
            }
        }

        return await refreshAttentionStates()
    }

    /// The attention state a row should show, or nil while nothing is pending.
    func attentionState(for session: SessionSummary) -> SessionRowAttentionState? {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return nil }
        return attentionStatesBySessionID[sessionID]
    }

    /// A settled row is unread only when its server timestamp moved past the
    /// last timestamp this device showed. No phone clock enters the comparison.
    func isUnread(_ session: SessionSummary) -> Bool {
        guard let sessionID = Self.nonEmpty(session.sessionId),
              let timestamp = Self.messageTime(for: session),
              let seen = seenMessageTimes[sessionID],
              !SessionRowView.isActiveStreaming(session),
              session.hasPendingUserMessage != true
        else { return false }
        return timestamp > seen
    }

    func canToggleUnread(_ session: SessionSummary) -> Bool {
        Self.nonEmpty(session.sessionId) != nil
            && Self.messageTime(for: session) != nil
            && !SessionRowView.isActiveStreaming(session)
            && session.hasPendingUserMessage != true
    }

    /// Every chat entry point selects a destination, so this one stamp covers
    /// rows, deep links, push, App Intents and Live Activity navigation.
    func beginViewing(_ session: SessionSummary) {
        viewingSessionID = Self.nonEmpty(session.sessionId)
        markSeen(session)
    }

    /// The next list load after a chat closes stamps its freshest server
    /// timestamp if it succeeds, including a reply completed during that visit.
    func noteReturn(from session: SessionSummary) {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return }
        if viewingSessionID == sessionID { viewingSessionID = nil }
        returnedFromSessionIDs.insert(sessionID)
        returnRevision &+= 1
    }

    func toggleUnread(_ session: SessionSummary) {
        guard canToggleUnread(session),
              let sessionID = Self.nonEmpty(session.sessionId),
              let timestamp = Self.messageTime(for: session)
        else { return }
        seenMessageTimes[sessionID] = isUnread(session) ? timestamp : timestamp.nextDown
        persistSeen()
    }

    private func markSeen(_ session: SessionSummary) {
        guard let sessionID = Self.nonEmpty(session.sessionId),
              let timestamp = Self.messageTime(for: session),
              (seenMessageTimes[sessionID] ?? 0) < timestamp
        else { return }
        seenMessageTimes[sessionID] = timestamp
        persistSeen()
    }

    private func reconcileUnread(
        _ visibleSessions: [SessionSummary],
        allSessions: [SessionSummary],
        returnedFromIDs: Set<String>
    ) {
        let presentIDs = Set(allSessions.compactMap { Self.nonEmpty($0.sessionId) })
        var updated = seenMessageTimes.filter { presentIDs.contains($0.key) }
        for session in visibleSessions {
            guard let sessionID = Self.nonEmpty(session.sessionId),
                  let timestamp = Self.messageTime(for: session)
            else { continue }
            if updated[sessionID] == nil
                || returnedFromIDs.contains(sessionID)
                || viewingSessionID == sessionID {
                updated[sessionID] = max(updated[sessionID] ?? timestamp, timestamp)
            }
        }
        guard updated != seenMessageTimes else { return }
        seenMessageTimes = updated
        persistSeen()
    }

    private func persistSeen() {
        unreadStore.save(seenMessageTimes, for: server)
    }

    private static func messageTime(for session: SessionSummary) -> Double? {
        guard let timestamp = session.lastMessageAt, timestamp.isFinite, timestamp > 0 else { return nil }
        return timestamp
    }

    /// One approval probe and one clarification probe per streaming row, on the
    /// tick the caller already runs. Sessions without an active stream are never
    /// probed, and there is no separate polling loop or timer. A row's two
    /// probes go out together, so N streaming rows cost about N round trips per
    /// tick instead of 2N.
    private func refreshAttentionStates() async -> ActiveSessionStateRefreshResult {
        let streamingSessions = sessions.filter { SessionRowView.isActiveStreaming($0) }
        guard !streamingSessions.isEmpty else {
            clearAttentionStates()
            return .unchanged
        }

        var refreshed: [String: SessionRowAttentionState] = [:]

        for session in streamingSessions {
            guard let sessionID = Self.nonEmpty(session.sessionId) else { continue }

            async let pendingApproval = client.approvalPending(sessionID: sessionID)
            async let pendingClarification = client.clarifyPending(sessionID: sessionID)

            // A failed probe is not evidence that nothing is pending, so it
            // keeps what the last successful tick knew rather than letting the
            // row fall back to "Working". The rule is deliberately simple: a
            // previous `.approval` masks any clarification, so it carries no
            // clarify knowledge, and a clarify probe that fails behind it
            // resolves to nothing pending.
            let previous = attentionStatesBySessionID[sessionID]
            var hasPendingApproval = false
            var hasPendingClarification = false
            var probeErrors: [Error] = []

            do {
                let response = try await pendingApproval
                hasPendingApproval = Self.hasPending(response.pending)
            } catch {
                probeErrors.append(error)
                hasPendingApproval = previous == .approval
            }

            do {
                let response = try await pendingClarification
                hasPendingClarification = Self.hasPending(response.pending)
            } catch {
                probeErrors.append(error)
                hasPendingClarification = previous == .input
            }

            for error in probeErrors {
                guard !isCancellationError(error) else { return .unchanged }
                if case APIError.unauthorized = error {
                    lastError = error
                    return .failed
                }
            }

            refreshed[sessionID] = SessionRowAttentionState.resolve(
                session: session,
                hasPendingApproval: hasPendingApproval,
                hasPendingClarification: hasPendingClarification
            )
        }

        guard refreshed != attentionStatesBySessionID else { return .unchanged }
        attentionStatesBySessionID = refreshed
        return .unchanged
    }

    private static func hasPending(_ pending: PendingApproval?) -> Bool {
        guard let pending else { return false }
        return !pending.isEmpty
    }

    private static func hasPending(_ pending: PendingClarification?) -> Bool {
        guard let pending else { return false }
        return !pending.isEmpty
    }

    private func clearAttentionStates() {
        guard !attentionStatesBySessionID.isEmpty else { return }
        attentionStatesBySessionID = [:]
    }

    /// Attention state only means something for a row the server still reports
    /// as streaming, so a reload that ends a stream drops that row's entry.
    private func pruneAttentionStates() {
        guard !attentionStatesBySessionID.isEmpty else { return }

        let streamingSessionIDs = Set(sessions.compactMap { session -> String? in
            guard SessionRowView.isActiveStreaming(session) else { return nil }
            return Self.nonEmpty(session.sessionId)
        })
        let pruned = attentionStatesBySessionID.filter { streamingSessionIDs.contains($0.key) }
        guard pruned != attentionStatesBySessionID else { return }
        attentionStatesBySessionID = pruned
    }

    func loadSessionForDeepLink(id rawSessionID: String, modelContext: ModelContext? = nil, isPush: Bool = false) async -> SessionSummary? {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }

        // A linked row on another profile opens like a tapped one: the server
        // moves to its profile first.
        if !isPush, let loadedSession = sessions.first(where: { $0.sessionId == sessionID }) {
            return await moveServerProfile(toProfileOf: loadedSession) ? loadedSession : nil
        }

        actionErrorMessage = nil
        lastError = nil

        if !isPush, let modelContext {
            do {
                if let cachedSession = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                    .first(where: { $0.sessionId == sessionID }) {
                    return await moveServerProfile(toProfileOf: cachedSession) ? cachedSession : nil
                }
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        // A push still reads the session live, but a listed row already says
        // which profile the server must be on.
        if let listedSession = sessions.first(where: { $0.sessionId == sessionID }) {
            guard await moveServerProfile(toProfileOf: listedSession) else { return nil }
        }

        do {
            let response: SessionResponse
            do {
                response = try await client.session(id: sessionID, includeMessages: false, messageLimit: nil)
            } catch let error as APIError {
                // The session lives on another profile: move there, then ask again once.
                guard let owner = error.mismatchedSessionProfile, !Task.isCancelled else { throw error }
                guard await moveServerProfile(to: owner, force: true) else { return nil }
                response = try await client.session(id: sessionID, includeMessages: false, messageLimit: nil)
            }
            guard !Task.isCancelled else { return nil }
            guard let sessionDetail = response.session else {
                if isPush { return nil }
                actionErrorMessage = String(localized: "The server did not return the linked session.")
                return nil
            }

            if isPush, sessionDetail.sessionId != sessionID { return nil }
            let session = SessionSummary(from: sessionDetail)
            if session.archived != true,
               session.shouldAppearInSessionList,
               !sessions.contains(where: { $0.sessionId == session.sessionId }) {
                sessions.insert(session, at: 0)
            }

            if let modelContext, session.shouldAppearInSessionList {
                do {
                    try CacheStore.cacheSession(session, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return session
        } catch {
            guard !Task.isCancelled else { return nil }
            if isPush, case APIError.http(404, _) = error { return nil }
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Moves the server to a row's profile, then imports external sessions
    /// before navigation, matching hermes-webui's `_openSidebarSession`. The
    /// server refuses every request for another profile's session, so the
    /// chat must not open until the move succeeds. A newer tap invalidates any
    /// older response so a slow import cannot replace the user's current
    /// destination.
    func sessionForOpening(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> SessionSummary? {
        sessionOpenGeneration &+= 1
        let generation = sessionOpenGeneration
        actionErrorMessage = nil
        lastError = nil

        guard !isViewingCachedData else { return session }

        guard await moveServerProfile(toProfileOf: session) else { return nil }
        guard !Task.isCancelled, generation == sessionOpenGeneration else { return nil }

        guard session.requiresExternalImport else { return session }

        guard let sessionID = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        do {
            let response = try await client.importExternalSession(id: sessionID)
            guard !Task.isCancelled, generation == sessionOpenGeneration else { return nil }
            guard let detail = response.session else {
                actionErrorMessage = String(localized: "The server did not return the linked session.")
                return nil
            }

            guard let importedSession = storeOpenedExternalSession(
                detail,
                listedSession: session,
                expectedSessionID: sessionID,
                modelContext: modelContext
            ) else {
                actionErrorMessage = String(localized: "The server did not return the linked session.")
                return nil
            }

            return importedSession
        } catch let importError {
            guard !Task.isCancelled,
                  generation == sessionOpenGeneration,
                  !isCancellationError(importError)
            else {
                return nil
            }

            // WebUI treats import as a refresh: if it fails, an already imported
            // session may still be available through the canonical detail route.
            do {
                let response = try await client.session(
                    id: sessionID,
                    includeMessages: false,
                    messageLimit: nil
                )
                guard !Task.isCancelled, generation == sessionOpenGeneration else { return nil }
                guard let detail = response.session,
                      let existingSession = storeOpenedExternalSession(
                          detail,
                          listedSession: session,
                          expectedSessionID: sessionID,
                          modelContext: modelContext
                      )
                else {
                    recordSessionImportFailure(importError)
                    return nil
                }

                return existingSession
            } catch {
                guard !Task.isCancelled,
                      generation == sessionOpenGeneration,
                      !isCancellationError(error)
                else {
                    return nil
                }

                recordSessionImportFailure(importError)
                return nil
            }
        }
    }

    private func storeOpenedExternalSession(
        _ detail: SessionDetail,
        listedSession: SessionSummary,
        expectedSessionID: String,
        modelContext: ModelContext?
    ) -> SessionSummary? {
        let currentSession = sessions.first(where: { $0.sessionId == expectedSessionID }) ?? listedSession
        let resolvedSession = currentSession.mergingImportedDetail(detail)
        guard resolvedSession.sessionId == expectedSessionID else { return nil }

        if let index = sessions.firstIndex(where: { $0.sessionId == expectedSessionID }) {
            sessions[index] = resolvedSession
        }

        if let modelContext, resolvedSession.shouldAppearInSessionList {
            do {
                try CacheStore.cacheSession(resolvedSession, serverURL: server, in: modelContext)
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        return resolvedSession
    }

    private func recordSessionImportFailure(_ error: Error) {
        lastError = error
        actionErrorMessage = (error as? APIError)?.serverMessage ?? error.localizedDescription
    }

    /// Moves the server to `session`'s profile before a session-scoped
    /// request; see `moveServerProfile(to:)`.
    private func moveServerProfile(toProfileOf session: SessionSummary) async -> Bool {
        guard let profile = Self.nonEmpty(session.profile) else { return true }
        return await moveServerProfile(to: profile)
    }

    /// Switches this client's server profile (the `hermes_profile` cookie) to
    /// `profile` when it is elsewhere, because the server answers any
    /// session-scoped request for another profile's session with 409. The pick
    /// stays: New Chat moves the server back to it. Returns false after
    /// surfacing a failed switch. Nothing to do in single-profile mode,
    /// offline, or before the server's profile is known, unless the server
    /// has just said the profile is elsewhere (`force`).
    private func moveServerProfile(to profile: String, force: Bool = false) async -> Bool {
        if !force {
            guard !isSingleProfileMode, !isViewingCachedData,
                  let current = serverProfileName ?? activeProfileName,
                  current != profile || serverProfileIsUncertain
            else { return true }
        }

        serverProfileIsUncertain = true
        do {
            let response = try await client.switchProfile(name: profile)
            if let message = Self.nonEmpty(response.error) {
                actionErrorMessage = String(localized: "Could not switch to the “\(profile)” profile: \(message)")
                return false
            }

            let serverProfile = Self.nonEmpty(response.active) ?? profile
            serverProfileName = serverProfile
            serverProfileIsUncertain = false
            profileMovedForRow = serverProfile == activeProfileName ? nil : serverProfile
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            let detail = (error as? APIError)?.serverMessage ?? error.localizedDescription
            actionErrorMessage = String(localized: "Could not switch to the “\(profile)” profile: \(detail)")
            return false
        }
    }

    func invalidateSessionOpening() {
        sessionOpenGeneration &+= 1
    }

    func setPinned(
        _ pinned: Bool,
        for session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }
        guard await moveServerProfile(toProfileOf: session) else { return false }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.setPinned(pinned, sessionID: sessionId)
        }
    }

    func archive(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }
        guard await moveServerProfile(toProfileOf: session) else { return false }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.archive(sessionID: sessionId)
        }
    }

    func delete(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }
        guard await moveServerProfile(toProfileOf: session) else { return false }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.delete(sessionID: sessionId)
        }
    }

    func isMutating(_ session: SessionSummary) -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else { return false }
        return mutatingSessionIDs.contains(sessionId)
    }

    func rename(_ session: SessionSummary, to rawTitle: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to rename a session.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let title = Self.nonEmpty(rawTitle) else {
            actionErrorMessage = String(localized: "Enter a session title.")
            return false
        }

        isRenamingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isRenamingSession = false }
        guard await moveServerProfile(toProfileOf: session) else { return false }

        do {
            let response = try await sessionMutator.rename(sessionID: sessionId, title: title)
            if let error = Self.nonEmpty(response.error) {
                actionErrorMessage = error
                return false
            }

            let resolvedTitle = Self.nonEmpty(response.session?.title) ?? title
            let baseSession = sessions.first(where: { $0.sessionId == sessionId }) ?? session
            let updatedSession = baseSession.replacingTitle(with: resolvedTitle)
            if let existingIndex = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                sessions[existingIndex] = updatedSession
            }

            if let modelContext {
                do {
                    try CacheStore.cacheSession(updatedSession, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func duplicate(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> SessionSummary? {
        guard SessionRowActionPolicy.canDuplicate(session) else {
            actionErrorMessage = String(localized: "This command is not available in the mobile app.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil
        guard await moveServerProfile(toProfileOf: session) else { return nil }

        do {
            let result = try await sessionMutator.duplicate(sessionID: sessionId)

            guard let duplicatedSession = result.session else {
                actionErrorMessage = result.errorMessage
                return nil
            }

            await load(modelContext: modelContext)
            if !sessions.contains(where: { $0.sessionId == duplicatedSession.sessionId }) {
                sessions.insert(duplicatedSession, at: 0)

                if let modelContext {
                    do {
                        try CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }
            return duplicatedSession
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Downloads the session transcript (`GET /api/session/export`) and writes
    /// it to a unique temp directory so the share sheet can offer it as a file
    /// with a real filename. Returns the file URL, or nil after surfacing the
    /// failure through the standard action-error alert. The caller owns
    /// cleanup of the returned file's parent directory after sharing.
    func export(_ session: SessionSummary, format: SessionExportFormat) async -> URL? {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to export a session.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        // Reuses the per-session mutation gate: it disables the row's other
        // actions while the download runs (the "progress state") and blocks a
        // double-tap from firing two exports.
        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil
        guard await moveServerProfile(toProfileOf: session) else { return nil }

        do {
            let file = try await client.exportSession(
                id: sessionId,
                format: format,
                fallbackTitle: session.title
            )

            let directory = Self.exportsRootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileURL = directory.appendingPathComponent(file.filename)
            try file.data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            guard !isCancellationError(error) else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func loadProjects() async {
        isLoadingProjects = true
        actionErrorMessage = nil
        lastError = nil
        defer { isLoadingProjects = false }

        do {
            let response = try await client.projects(allProfiles: true)
            projects = response.projects ?? []
        } catch {
            guard !isCancellationError(error) else { return }

            lastError = error
            actionErrorMessage = error.localizedDescription
        }
    }

    func move(_ session: SessionSummary, to projectID: String?, modelContext: ModelContext? = nil) async {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return
        }

        guard beginSessionMutation(sessionId) else { return }
        defer { endSessionMutation(sessionId) }

        isMovingSession = true
        defer { isMovingSession = false }
        guard await moveServerProfile(toProfileOf: session) else { return }

        _ = await mutate(modelContext: modelContext) {
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
        }
    }

    func createProject(
        named rawName: String,
        color: String,
        moving session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard let sessionId = session.sessionId else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        isMovingSession = true
        defer {
            isCreatingProject = false
            isMovingSession = false
        }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a new project without moving any session into it.
    ///
    /// Mirrors ``createProject(named:color:moving:modelContext:)`` but skips the
    /// `sessionMutator.move(...)` step, so the Projects sidebar's standalone
    /// "Add project" button can make an empty, unassigned project.
    func createEmptyProject(
        named rawName: String,
        color: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        defer { isCreatingProject = false }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ project: ProjectSummary, modelContext: ModelContext? = nil) async -> Bool {
        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        isDeletingProject = true
        actionErrorMessage = nil
        lastError = nil
        defer { isDeletingProject = false }

        do {
            _ = try await client.deleteProject(id: projectID)
            projects.removeAll { $0.projectId == projectID }
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ project: ProjectSummary, named rawName: String, color: String?) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isRenamingProject = true
        defer { isRenamingProject = false }

        do {
            let response = try await client.renameProject(id: projectID, name: name, color: color)
            guard let renamedProject = response.project else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project.")
                return false
            }

            guard renamedProject.projectId?.isEmpty == false else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project ID.")
                return false
            }

            upsertProject(renamedProject)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a new session on `profile` (the "New Chat in <Profile>" App Intent, #339),
    /// or on the list's active profile for the "+" button / plain New Chat. The profile is
    /// sent explicitly so the session never depends on the client's active-profile cookie,
    /// which an opened chat may have moved; only a list that never loaded its profile
    /// leaves the choice to the server. Plain New Chat also moves the server back to
    /// the list's profile first when opening a row left it elsewhere: the new chat's
    /// own requests would otherwise be refused, and its workspace comes from the
    /// server's profile.
    func createSession(modelContext: ModelContext? = nil, profile: String? = nil) async -> SessionSummary? {
        isCreatingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isCreatingSession = false }

        if Self.nonEmpty(profile) == nil, let activeProfileName {
            guard await moveServerProfile(to: activeProfileName) else { return nil }
        }

        do {
            let workspaces = try await client.workspaces()
            let workspace = workspaces.last ?? workspaces.workspaces?.compactMap(\.path).first
            let response = try await client.createSession(
                workspace: workspace,
                model: nil,
                modelProvider: nil,
                profile: Self.nonEmpty(profile) ?? activeProfileName
            )

            guard let sessionDetail = response.session else {
                actionErrorMessage = String(localized: "The server did not return the new session.")
                return nil
            }

            let newSession = SessionSummary(from: sessionDetail)
            guard newSession.sessionId?.isEmpty == false else {
                actionErrorMessage = String(localized: "The server did not return the new session ID.")
                return nil
            }

            if newSession.shouldAppearInSessionList {
                if let existingIndex = sessions.firstIndex(where: { $0.sessionId == newSession.sessionId }) {
                    sessions[existingIndex] = newSession
                } else {
                    sessions.insert(newSession, at: 0)
                }

                if let modelContext {
                    do {
                        try CacheStore.cacheSession(newSession, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }

            return newSession
        } catch {
            guard !isCancellationError(error) else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Drops any empty Untitled placeholders still held in memory. Used when
    /// returning from the pending new-chat flow so stale rows cannot flash during
    /// the navigation pop animation.
    func removeEmptySidebarPlaceholders() {
        let filtered = sessions.filter(\.shouldAppearInSessionList)
        guard filtered.count != sessions.count else { return }
        sessions = filtered
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func activeStreamIDs(in sessions: [SessionSummary]) -> [String] {
        normalizedStreamIDs(sessions.compactMap(\.activeStreamId))
    }

    private static func normalizedStreamIDs(_ rawStreamIDs: [String]) -> [String] {
        Array(Set(rawStreamIDs.compactMap(nonEmpty))).sorted()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sortedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) {
                return left.pinned == true
            }

            return timestamp(for: left) > timestamp(for: right)
        }
    }

    private static func timestamp(for session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }

    private static func searchableText(for session: SessionSummary) -> String {
        [
            session.title,
            session.workspace,
            session.model,
            session.modelProvider,
            session.profile,
            session.sourceLabel
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    /// `archivedCount` is applied inside the same transaction as the rows so the
    /// bottom Archived entry inserts/removes with the list mutation animation.
    private func applySessions(
        _ newSessions: [SessionSummary],
        archivedCount newArchivedCount: Int?,
        animation: Animation?
    ) {
        guard let animation else {
            sessions = newSessions
            archivedCount = newArchivedCount
            pruneAttentionStates()
            return
        }

        withAnimation(animation) {
            sessions = newSessions
            archivedCount = newArchivedCount
        }
        pruneAttentionStates()
    }

    /// Content-match rows narrowed to sessions the list can actually show, in
    /// server order, plus each row's excerpt when the server sent one.
    private func contentMatches(
        from sessions: [SessionSummary]
    ) -> (sessionIDs: [String], excerpts: [String: String]) {
        let locallyVisibleSessionIDs = Set(self.sessions.compactMap { session -> String? in
            guard session.archived != true, let sessionID = session.sessionId, !sessionID.isEmpty else {
                return nil
            }

            return sessionID
        })
        var seenSessionIDs = Set<String>()
        var sessionIDs: [String] = []
        var excerpts: [String: String] = [:]

        for session in sessions {
            guard session.matchType?.lowercased() == "content",
                  let sessionID = session.sessionId,
                  locallyVisibleSessionIDs.contains(sessionID),
                  !seenSessionIDs.contains(sessionID)
            else {
                continue
            }

            seenSessionIDs.insert(sessionID)
            sessionIDs.append(sessionID)

            if let preview = session.matchPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
               !preview.isEmpty {
                excerpts[sessionID] = preview
            }
        }

        return (sessionIDs, excerpts)
    }

    private func timestamp(for session: SessionSummary) -> Double {
        Self.timestamp(for: session)
    }

    private func date(for session: SessionSummary) -> Date? {
        let value = timestamp(for: session)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private func beginSessionMutation(_ sessionId: String) -> Bool {
        mutatingSessionIDs.insert(sessionId).inserted
    }

    private func endSessionMutation(_ sessionId: String) {
        mutatingSessionIDs.remove(sessionId)
    }

    private func upsertProject(_ project: ProjectSummary) {
        guard let projectID = project.projectId, !projectID.isEmpty else { return }

        if let existingIndex = projects.firstIndex(where: { $0.projectId == projectID }) {
            projects[existingIndex] = project
        } else {
            projects.append(project)
        }
    }

    private func applyActiveProfile(
        _ response: ProfilesResponse,
        fallbackProfile: ProfileSummary? = nil,
        fallbackDefaultModel: String? = nil
    ) {
        profileOptions = response.profiles ?? profileOptions

        // Tolerant: only a present field moves the flag, so an older server
        // (or the carried-forward switch-response value) keeps today's behavior.
        if let singleProfileMode = response.singleProfileMode {
            isSingleProfileMode = singleProfileMode
        }

        // Keep the App Intents profile cache fresh so the "New Chat in <Profile>" picker
        // (#339) stays populated when the Shortcuts app resolves it in the background, where
        // a live, authenticated fetch may not be possible, then nudge the system to (re-)index
        // the parameterized App Shortcut (iOS only indexes it once its suggested values exist).
        // A nil `profiles` (field absent/undecoded) is left untouched — tolerant decoding — but
        // an explicit empty list is forwarded so `save([])` can clear a stale picker if the
        // server ever reports none.
        if let profiles = response.profiles {
            let changed = ProfileEntityCache.shared.save(profiles)
            ProfileEntityProvider.refreshAppShortcuts(changed: changed)
        }

        // The server's profile becomes the pick unless it is only where the
        // list moved it to reach a row. Any other move (Settings, a chat's
        // profile picker) is the user choosing a profile.
        let serverProfile = response.effectiveDefaultProfileName
        let keepsPick = activeProfileName != nil
            && serverProfile != nil
            && serverProfile == profileMovedForRow
        if let serverProfile {
            serverProfileName = serverProfile
            serverProfileIsUncertain = false
        }
        if !keepsPick {
            profileMovedForRow = nil
        }

        let profileName = keepsPick ? activeProfileName : serverProfile
        let profile = response.profile(matching: profileName) ?? (keepsPick ? nil : fallbackProfile)

        activeProfileName = profileName
        activeProfileDisplayName = response.displayName(for: profileName)
            ?? profile?.displayName
        activeProfileModel = Self.nonEmpty(profile?.model) ?? Self.nonEmpty(fallbackDefaultModel)
        activeProfileProvider = Self.nonEmpty(profile?.provider)
    }

    private func mutate(
        modelContext: ModelContext? = nil,
        animation: Animation? = nil,
        _ operation: () async throws -> Void
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        do {
            try await operation()
            return await load(modelContext: modelContext, animation: animation)
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }

}
