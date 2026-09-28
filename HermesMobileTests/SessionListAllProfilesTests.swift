import SwiftData
import XCTest
@testable import HermesMobile

/// All shows every profile's chats (`all_profiles=1`), groups messaging chats
/// per platform, and opens a row from another profile only after the server
/// moves to it, without changing the profile New Chat uses. The server moves
/// back to the pick when that chat closes or the row action ends.
final class SessionListAllProfilesTests: XCTestCase {
    private let server = URL(string: "https://example.test")!

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Requests

    @MainActor
    func testListSearchAndProjectsRequestsAskForEveryProfile() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("w1", profile: "default", at: 10)])
        var listQueries: [String?] = []
        let viewModel = SessionListViewModel(server: server, client: makeClient { request in
            if request.url?.path == "/api/sessions" { listQueries.append(request.url?.query) }
            return try fake.handle(request)
        })

        await viewModel.load()
        await viewModel.searchSessions(query: "planning", debounceNanoseconds: 0)
        await viewModel.loadProjects()

        // Every profile's rows without hidden ones, then the cookie profile's plain list.
        XCTAssertEqual(listQueries, ["all_profiles=1&exclude_hidden=1", nil])
        XCTAssertEqual(
            fake.query(for: "/api/sessions/search"),
            ["q": "planning", "content": "1", "depth": "5", "all_profiles": "1"]
        )
        XCTAssertEqual(fake.query(for: "/api/projects"), ["all_profiles": "1"])
    }

    /// The reported bug: a WebUI chat created in another profile, outside any
    /// project, never showed up in All.
    @MainActor
    func testWebUIChatInAnotherProfileWithoutAProjectAppearsInAll() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("mine", profile: "default", at: 10),
            Self.webui("elsewhere", profile: "opensource", at: 20)
        ])
        let viewModel = makeViewModel(fake)

        await viewModel.load()
        await viewModel.loadActiveProfile()
        let groups = viewModel.sessionListGroups(searchText: "", selectedProjectID: nil)

        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["elsewhere", "mine"])
        XCTAssertEqual(viewModel.listsAllProfiles, true)
        XCTAssertEqual(viewModel.serverProfileName, "default")
    }

    // MARK: - Profile chip

    @MainActor
    func testProfileChipNamesOnlyNonDefaultProfiles() async throws {
        let fake = AllProfilesServerFake(active: "opensource", rows: [
            Self.webui("default-row", profile: "default", at: 10),
            Self.webui("open-row", profile: "opensource", at: 20),
            Self.webui("unnamed-row", profile: nil, at: 30)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()

        XCTAssertNil(viewModel.profileChipLabel(for: try row("default-row", in: viewModel)))
        XCTAssertEqual(viewModel.profileChipLabel(for: try row("open-row", in: viewModel)), "opensource")
        XCTAssertNil(viewModel.profileChipLabel(for: try row("unnamed-row", in: viewModel)))
    }

    @MainActor
    func testSingleProfileModeShowsNoChipAndNoFilter() async throws {
        let fake = AllProfilesServerFake(
            active: "work",
            profiles: ["work"],
            rows: [Self.webui("w1", profile: "work", at: 10)],
            singleProfileMode: true
        )
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()

        XCTAssertTrue(viewModel.isSingleProfileMode)
        XCTAssertNil(viewModel.profileChipLabel(for: try row("w1", in: viewModel)))
        XCTAssertEqual(viewModel.profileFilterOptions, [])
    }

    /// An isolated-profile server ignores `all_profiles` and answers false: every
    /// row is the active profile's, so neither chips nor the filter apply.
    @MainActor
    func testServerThatListsOnlyTheActiveProfileShowsNoChipAndNoFilter() async throws {
        let fake = AllProfilesServerFake(
            active: "opensource",
            rows: [
                Self.webui("open-row", profile: "opensource", at: 10),
                Self.webui("default-row", profile: "default", at: 20)
            ],
            honorsAllProfiles: false
        )
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["open-row"])
        XCTAssertEqual(viewModel.listsAllProfiles, false)
        XCTAssertNil(viewModel.profileChipLabel(for: try row("open-row", in: viewModel)))
        XCTAssertEqual(viewModel.profileFilterOptions, [])
    }

    // MARK: - Messaging groups

    @MainActor
    func testMessagingChatsGroupPerPlatformBetweenScheduledAndSessions() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("webui", profile: "default", at: 90),
            Self.external("cli", profile: "default", source: "cli", at: 80),
            Self.external("tg-1", profile: "default", source: "telegram", at: 70),
            Self.external("tg-2", profile: "opensource", source: "telegram", at: 75),
            Self.external("wa-1", profile: "default", source: "whatsapp", at: 60),
            Self.external("imsg", profile: "default", source: "bluebubbles", at: 50),
            // A platform the table does not know still groups when the server marks it messaging.
            Self.external("line-1", profile: "default", source: "line", at: 40),
            Self.webui("cron_nightly", profile: "default", at: 30, ["source_tag": "cron"]),
            // A handed-off chat now owned by the WebUI stays in Sessions.
            Self.webui("imported", profile: "default", at: 20, ["raw_source": "telegram"])
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()

        let groups = viewModel.sessionListGroups(searchText: "", selectedProjectID: nil)

        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["webui", "cli", "imported"])
        XCTAssertEqual(groups.scheduled.compactMap(\.sessionId), ["cron_nightly"])
        XCTAssertEqual(groups.messaging.map(\.title), ["iMessage", "Line", "Telegram", "WhatsApp"])
        XCTAssertEqual(groups.messaging.map(\.platform), ["bluebubbles", "line", "telegram", "whatsapp"])
        XCTAssertEqual(
            groups.messaging.first { $0.platform == "telegram" }?.sessions.compactMap(\.sessionId),
            ["tg-2", "tg-1"]
        )
        XCTAssertEqual(groups.messaging.map(\.totalCount), [1, 1, 2, 1])
    }

    /// Search shows matching messaging rows inside their expanded disclosure,
    /// like Scheduled; the badge keeps counting the platform's rows.
    @MainActor
    func testSearchShowsMatchingMessagingRowsInlineAndKeepsPlatformTotals() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.external("tg-1", profile: "default", source: "telegram", at: 70, title: "Invoice question"),
            Self.external("tg-2", profile: "default", source: "telegram", at: 60, title: "Weekend plans"),
            Self.external("wa-1", profile: "default", source: "whatsapp", at: 50, title: "Groceries"),
            Self.webui("webui", profile: "default", at: 40, title: "Invoice draft")
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()

        let groups = viewModel.sessionListGroups(searchText: "invoice", selectedProjectID: nil)

        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["webui"])
        XCTAssertEqual(groups.messaging.map(\.platform), ["telegram"])
        XCTAssertEqual(groups.messaging.first?.sessions.compactMap(\.sessionId), ["tg-1"])
        XCTAssertEqual(groups.messaging.first?.totalCount, 2)
    }

    // MARK: - Profile filter

    @MainActor
    func testProfileFilterNarrowsRowsMessagingScheduledAndProjectCounts() async throws {
        let fake = AllProfilesServerFake(
            active: "default",
            rows: [
                Self.webui("d-webui", profile: "default", at: 90, ["project_id": "p-default"]),
                Self.webui("o-webui", profile: "opensource", at: 80, ["project_id": "p-open"]),
                Self.webui("o-webui-2", profile: "opensource", at: 75, ["project_id": "p-open"]),
                Self.external("d-tg", profile: "default", source: "telegram", at: 70),
                Self.external("o-tg", profile: "opensource", source: "telegram", at: 60),
                Self.external("o-signal", profile: "opensource", source: "signal", at: 55),
                Self.webui("cron_default", profile: "default", at: 50, ["source_tag": "cron"]),
                Self.webui("cron_open", profile: "opensource", at: 40, ["source_tag": "cron"])
            ],
            projects: [
                ["project_id": "p-default", "name": "Hermex", "profile": "default"],
                ["project_id": "p-open", "name": "Open work", "profile": "opensource"]
            ]
        )
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        await viewModel.loadProjects()

        XCTAssertEqual(viewModel.profileFilterOptions, ["default", "opensource", "openai_sol"])
        let filter = try XCTUnwrap(viewModel.effectiveProfileFilter("opensource"))
        let groups = viewModel.sessionListGroups(searchText: "", selectedProjectID: nil, profileFilter: filter)

        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["o-webui", "o-webui-2"])
        XCTAssertEqual(groups.messaging.map(\.platform), ["signal", "telegram"])
        XCTAssertEqual(groups.messaging.last?.sessions.compactMap(\.sessionId), ["o-tg"])
        XCTAssertEqual(groups.scheduled.compactMap(\.sessionId), ["cron_open"])
        XCTAssertEqual(groups.totalScheduledCount, 1)

        let projects = viewModel.visibleProjects(profileFilter: filter)
        XCTAssertEqual(projects.compactMap(\.projectId), ["p-open"])
        XCTAssertEqual(
            viewModel.sessionCount(inProject: try XCTUnwrap(projects.first), automatedVisibility: .showAll, profileFilter: filter),
            2
        )
        XCTAssertEqual(viewModel.visibleProjects(profileFilter: nil).count, 2)

        let unfiltered = viewModel.sessionListGroups(searchText: "", selectedProjectID: nil)
        XCTAssertEqual(unfiltered.ordinary.count, 3)
        XCTAssertEqual(unfiltered.totalScheduledCount, 2)

        // A stored filter for a profile the server no longer lists shows everything.
        XCTAssertNil(viewModel.effectiveProfileFilter("retired"))
        XCTAssertNil(viewModel.effectiveProfileFilter(""))
    }

    func testProfileFilterAndMessagingDisclosuresAreRememberedPerServer() throws {
        let suiteName = "SessionListAllProfilesTests.perServer"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let serverA = URL(string: "https://alpha.example.test")!
        let serverB = URL(string: "https://beta.example.test")!

        defaults.set("opensource", forKey: SessionListProfileFilterSettings.key(for: serverA))
        let expanded = SessionSidebarDisclosureSettings.togglingMessagingPlatform("telegram", in: "")
        defaults.set(expanded, forKey: SessionSidebarDisclosureSettings.expandedMessagingPlatformsKey(for: serverA))

        XCTAssertEqual(defaults.string(forKey: SessionListProfileFilterSettings.key(for: serverA)), "opensource")
        XCTAssertNil(defaults.string(forKey: SessionListProfileFilterSettings.key(for: serverB)))
        XCTAssertNil(defaults.string(forKey: SessionSidebarDisclosureSettings.expandedMessagingPlatformsKey(for: serverB)))
        XCTAssertEqual(SessionSidebarDisclosureSettings.expandedMessagingPlatforms(from: expanded), ["telegram"])

        let both = SessionSidebarDisclosureSettings.togglingMessagingPlatform("whatsapp", in: expanded)
        XCTAssertEqual(SessionSidebarDisclosureSettings.expandedMessagingPlatforms(from: both), ["telegram", "whatsapp"])
        let collapsed = SessionSidebarDisclosureSettings.togglingMessagingPlatform("telegram", in: both)
        XCTAssertEqual(SessionSidebarDisclosureSettings.expandedMessagingPlatforms(from: collapsed), ["whatsapp"])
    }

    // MARK: - Opening a row from another profile

    /// Guards the fake: without a switch it refuses the session like the server.
    @MainActor
    func testTheFakeRefusesAnotherProfilesSessionUntilTheProfileMoves() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("open-1", profile: "opensource", at: 10)])
        let client = makeClient(fake)

        do {
            _ = try await client.session(id: "open-1", includeMessages: false, messageLimit: nil)
            XCTFail("Expected the profile mismatch")
        } catch let error as APIError {
            XCTAssertEqual(error.mismatchedSessionProfile, "opensource")
        }
        XCTAssertEqual(fake.violations.count, 1)
    }

    @MainActor
    func testOpeningAWebUIRowFromAnotherProfileSwitchesBeforeAnySessionRequest() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("mine", profile: "default", at: 10),
            Self.webui("open-1", profile: "opensource", at: 20)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        fake.clearRequests()

        let opened = await viewModel.sessionForOpening(try row("open-1", in: viewModel))
        // The chat's own first requests, which start as soon as it opens.
        let chatClient = makeClient(fake)
        _ = try await chatClient.session(id: "open-1", includeMessages: true, messageLimit: 50)
        _ = try await chatClient.sessionYolo(sessionID: "open-1")

        XCTAssertEqual(opened?.sessionId, "open-1")
        XCTAssertEqual(fake.requests, ["POST /api/profile/switch", "GET /api/session", "GET /api/session/yolo"])
        XCTAssertEqual(fake.switchedProfiles, ["opensource"])
        XCTAssertEqual(fake.violations, [])
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(viewModel.activeProfileName, "default", "Opening a row never changes the pick")
        XCTAssertEqual(viewModel.serverProfileName, "opensource")

        // A row on the profile the server already selects needs no second switch.
        fake.clearRequests()
        let again = await viewModel.sessionForOpening(try row("open-1", in: viewModel))
        XCTAssertEqual(again?.sessionId, "open-1")
        XCTAssertEqual(fake.requests, [])
    }

    @MainActor
    func testOpeningExternalRowsFromAnotherProfileSwitchesBeforeTheImport() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.external("tg-sol", profile: "openai_sol", source: "telegram", at: 20),
            Self.external("cli-open", profile: "opensource", source: "cli", at: 10)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        fake.clearRequests()

        let telegram = await viewModel.sessionForOpening(try row("tg-sol", in: viewModel))
        let cli = await viewModel.sessionForOpening(try row("cli-open", in: viewModel))

        XCTAssertEqual(telegram?.sessionId, "tg-sol")
        XCTAssertEqual(cli?.sessionId, "cli-open")
        XCTAssertEqual(fake.requests, [
            "POST /api/profile/switch", "POST /api/session/import_cli",
            "POST /api/profile/switch", "POST /api/session/import_cli"
        ])
        XCTAssertEqual(fake.switchedProfiles, ["openai_sol", "opensource"])
        XCTAssertEqual(fake.violations, [])
        XCTAssertEqual(viewModel.activeProfileName, "default")
    }

    @MainActor
    func testFailedSwitchShowsTheErrorAndDoesNotOpenTheRow() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.external("tg-ghost", profile: "ghost", source: "telegram", at: 20)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        fake.clearRequests()

        let opened = await viewModel.sessionForOpening(try row("tg-ghost", in: viewModel))

        XCTAssertNil(opened)
        XCTAssertEqual(fake.requests, ["POST /api/profile/switch"])
        let message = try XCTUnwrap(viewModel.actionErrorMessage)
        XCTAssertTrue(message.contains("ghost"), message)
        XCTAssertTrue(message.contains("Profile not found"), message)
        XCTAssertEqual(viewModel.serverProfileName, "default")
    }

    /// PR #8: New Chat creates on the pick. After a row moved the server to
    /// another profile, returning to the list moves it back, so the new chat's
    /// own requests and its workspace belong to the pick.
    @MainActor
    func testNewChatAfterOpeningAForeignRowSwitchesBackAndKeepsThePick() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("open-1", profile: "opensource", at: 20)])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        let opened = try await openChat(try row("open-1", in: viewModel), in: viewModel)

        // Returning to the list moves the server back, then reloads the rows
        // and the profile; the pick stays.
        await viewModel.destinationDidChange(from: .session(opened), to: nil).value
        await viewModel.load()
        await viewModel.loadActiveProfile()
        XCTAssertEqual(viewModel.activeProfileName, "default")
        XCTAssertEqual(viewModel.serverProfileName, "default")
        fake.clearRequests()

        let createdSession = await viewModel.createSession()
        let created = try XCTUnwrap(createdSession)
        _ = try await makeClient(fake).sessionYolo(sessionID: try XCTUnwrap(created.sessionId))

        XCTAssertEqual(fake.requests, ["GET /api/workspaces", "POST /api/session/new", "GET /api/session/yolo"])
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default"])
        XCTAssertEqual(fake.createdSessionProfiles, ["default"])
        XCTAssertEqual(created.profile, "default")
        XCTAssertEqual(created.workspace, "/work/default")
        XCTAssertEqual(fake.violations, [])
        XCTAssertEqual(viewModel.activeProfileName, "default")
        XCTAssertEqual(viewModel.serverProfileName, "default")
    }

    /// A move the list did not make (Settings, a chat's profile picker) is the
    /// user choosing a profile, and the pick follows it.
    @MainActor
    func testAProfileChangeMadeElsewhereStillBecomesThePick() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("open-1", profile: "opensource", at: 20)])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        _ = await viewModel.sessionForOpening(try row("open-1", in: viewModel))

        fake.setActiveProfile("openai_sol")
        await viewModel.loadActiveProfile()

        XCTAssertEqual(viewModel.activeProfileName, "openai_sol")
        XCTAssertEqual(viewModel.serverProfileName, "openai_sol")
    }

    @MainActor
    func testMutatingARowFromAnotherProfileSwitchesFirst() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("open-1", profile: "opensource", at: 20)])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        fake.clearRequests()

        let didPin = await viewModel.setPinned(true, for: try row("open-1", in: viewModel))

        XCTAssertTrue(didPin)
        // The pin on the row's profile, then the list back on the pick.
        XCTAssertEqual(fake.requests, [
            "POST /api/profile/switch", "POST /api/session/pin", "POST /api/profile/switch",
            "GET /api/sessions", "GET /api/sessions"
        ])
        XCTAssertEqual(fake.violations, [])
        XCTAssertEqual(viewModel.activeProfileName, "default")
    }

    @MainActor
    func testDeepLinkToALoadedRowFromAnotherProfileSwitchesFirst() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("open-1", profile: "opensource", at: 20)])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        fake.clearRequests()

        let session = await viewModel.loadSessionForDeepLink(id: "open-1")

        XCTAssertEqual(session?.sessionId, "open-1")
        XCTAssertEqual(fake.requests, ["POST /api/profile/switch"])
        XCTAssertEqual(fake.activeProfile, "opensource")
    }

    /// A push is looked up live. The listed row's profile moves the server
    /// first; a session the list has not loaded is found through the 409,
    /// which names its profile.
    @MainActor
    func testPushToAnotherProfilesSessionSwitchesAndLooksItUpLive() async throws {
        let fake = AllProfilesServerFake(
            active: "default",
            rows: [
                Self.webui("open-1", profile: "opensource", at: 20),
                Self.webui("sol-unlisted", profile: "openai_sol", at: 10)
            ],
            unlistedSessionIDs: ["sol-unlisted"]
        )
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["open-1"])
        fake.clearRequests()

        let listed = await viewModel.loadSessionForDeepLink(id: "open-1", isPush: true)
        XCTAssertEqual(listed?.sessionId, "open-1")
        XCTAssertEqual(fake.requests, ["POST /api/profile/switch", "GET /api/session"])
        XCTAssertEqual(fake.violations, [])

        fake.clearRequests()
        let unlisted = await viewModel.loadSessionForDeepLink(id: "sol-unlisted", isPush: true)
        XCTAssertEqual(unlisted?.sessionId, "sol-unlisted")
        XCTAssertEqual(fake.requests, ["GET /api/session", "POST /api/profile/switch", "GET /api/session"])
        XCTAssertEqual(fake.switchedProfiles.last, "openai_sol")
        XCTAssertEqual(viewModel.activeProfileName, "default")
    }

    // MARK: - Returning the profile to the pick

    /// Closing a chat from another profile moves the server back to the pick
    /// before any screen reached from the list loads or saves.
    @MainActor
    func testClosingAForeignChatReturnsTheServerSoListScreensUseThePick() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("mine", profile: "default", at: 10),
            Self.webui("open-1", profile: "opensource", at: 20)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        let opened = try await openChat(try row("open-1", in: viewModel), in: viewModel)
        XCTAssertEqual(fake.activeProfile, "opensource")

        await viewModel.destinationDidChange(from: .session(opened), to: nil).value

        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default"])
        XCTAssertEqual(viewModel.serverProfileName, "default")
        XCTAssertEqual(viewModel.activeProfileName, "default")
        XCTAssertTrue(viewModel.isServerOnPick)
        try await assertScreensReachedFromTheList(use: "default", fake)
    }

    /// A row action on another profile's row returns the server to the pick
    /// once it ends, though the user never left the list.
    @MainActor
    func testARowActionOnAForeignRowReturnsTheServerToThePick() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("mine", profile: "default", at: 10),
            Self.webui("open-1", profile: "opensource", at: 20)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()

        let didPin = await viewModel.setPinned(true, for: try row("open-1", in: viewModel))
        let didRename = await viewModel.rename(try row("open-1", in: viewModel), to: "Renamed")

        XCTAssertTrue(didPin)
        XCTAssertTrue(didRename)
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default", "opensource", "default"])
        XCTAssertEqual(fake.violations, [])
        XCTAssertEqual(viewModel.activeProfileName, "default")
        XCTAssertEqual(viewModel.serverProfileName, "default")
        try await assertScreensReachedFromTheList(use: "default", fake)
    }

    /// Beside an open chat (regular width), a row action returns the server
    /// to that chat's profile rather than the pick.
    @MainActor
    func testARowActionBesideAForeignChatReturnsTheServerToTheChat() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("mine", profile: "default", at: 10),
            Self.webui("open-1", profile: "opensource", at: 20)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        _ = try await openChat(try row("open-1", in: viewModel), in: viewModel)

        let didPin = await viewModel.setPinned(true, for: try row("mine", in: viewModel))

        XCTAssertTrue(didPin)
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default", "opensource"])
        XCTAssertEqual(fake.violations, [])
        XCTAssertEqual(viewModel.serverProfileName, "opensource")
        XCTAssertEqual(viewModel.activeProfileName, "default")
    }

    /// An action on another profile's row or project reloads the list only
    /// once the server is back on the pick. The list's second request follows
    /// the cookie, so a reload on the owner's profile swapped the pick's cron
    /// runs in Scheduled for the owner's. Each action still loads the list
    /// once at most; rename patches the row in place.
    @MainActor
    func testScheduledKeepsThePicksCronRunsAfterARowActionOnAnotherProfile() async throws {
        let cronRuns: Set = ["cron-1", "cron-2", "cron-3"]
        let fake = AllProfilesServerFake(
            active: "default",
            rows: ["open-rename", "open-pin", "open-archive", "open-move", "open-delete"].map {
                Self.webui($0, profile: "opensource", at: 20)
            } + cronRuns.map {
                Self.webui($0, profile: "default", at: 30, [
                    "session_source": "cron", "source_tag": "cron", "project_id": "cron-project", "default_hidden": true
                ])
            },
            projects: [["project_id": "p-open", "name": "Open work", "profile": "opensource"]]
        )
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        await viewModel.loadProjects()
        func scheduled() -> Set<String> {
            Set(viewModel.sessionListGroups(searchText: "", selectedProjectID: nil).scheduled.compactMap(\.sessionId))
        }
        XCTAssertEqual(scheduled(), cronRuns)

        let actions: [(name: String, listRequests: Int, run: @MainActor () async throws -> Void)] = [
            ("rename", 0, { _ = await viewModel.rename(try self.row("open-rename", in: viewModel), to: "Renamed") }),
            ("pin", 2, { _ = await viewModel.setPinned(true, for: try self.row("open-pin", in: viewModel)) }),
            ("archive", 2, { _ = await viewModel.archive(try self.row("open-archive", in: viewModel)) }),
            ("move", 2, { await viewModel.move(try self.row("open-move", in: viewModel), to: "p-open") }),
            ("delete", 2, { _ = await viewModel.delete(try self.row("open-delete", in: viewModel)) }),
            ("delete project", 2, { _ = await viewModel.delete(try XCTUnwrap(viewModel.projects.first)) })
        ]
        for (name, listRequests, run) in actions {
            fake.clearRequests()
            try await run()

            let listProfiles = zip(fake.requests, fake.servedProfiles).compactMap { request, profile in
                request == "GET /api/sessions" ? profile : nil
            }
            XCTAssertNil(viewModel.actionErrorMessage, name)
            XCTAssertEqual(listProfiles, Array(repeating: "default", count: listRequests), "\(name): \(fake.requests)")
            XCTAssertEqual(scheduled(), cronRuns, name)
            XCTAssertEqual(fake.violations, [], name)
            XCTAssertEqual(viewModel.activeProfileName, "default", name)
            XCTAssertEqual(fake.activeProfile, "default", name)
        }
    }

    /// A screen opened while the return is pending, such as a deep link from a
    /// foreign chat straight to Tasks, loads only once the server is back on
    /// the pick.
    @MainActor
    func testAScreenOpenedBeforeTheReturnLandsWaitsForThePick() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("open-1", profile: "opensource", at: 20)])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        let opened = try await openChat(try row("open-1", in: viewModel), in: viewModel)

        let returning = viewModel.destinationDidChange(from: .session(opened), to: .utility(.tasks))
        XCTAssertFalse(viewModel.isServerOnPick, "The gate waits instead of showing Tasks")
        let failure = await viewModel.ensureServerOnPick()
        XCTAssertNil(failure)
        XCTAssertEqual(fake.activeProfile, "default")
        fake.clearRequests()
        await TasksViewModel(server: server, client: makeClient(fake)).load()
        await returning.value

        XCTAssertEqual(fake.servedProfiles.first, "default")
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default"], "The gate and the return make one switch")
    }

    /// PR #14's rule under the return: a profile picked in the foreign chat's
    /// own picker becomes the pick when the chat closes, and stays.
    @MainActor
    func testAProfilePickedInsideAForeignChatBecomesThePickWhenItCloses() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [Self.webui("open-1", profile: "opensource", at: 20)])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        let opened = try await openChat(try row("open-1", in: viewModel), in: viewModel)

        fake.setActiveProfile("openai_sol")
        await viewModel.destinationDidChange(from: .session(opened), to: nil).value

        XCTAssertEqual(viewModel.activeProfileName, "openai_sol")
        XCTAssertEqual(viewModel.serverProfileName, "openai_sol")
        XCTAssertEqual(fake.switchedProfiles, ["opensource"])
        try await assertScreensReachedFromTheList(use: "openai_sol", fake)
    }

    /// No switch when the server is already on the profile it needs.
    @MainActor
    func testNoSwitchWhenTheServerIsAlreadyOnTheNeededProfile() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("mine", profile: "default", at: 10),
            Self.webui("open-1", profile: "opensource", at: 20)
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        fake.clearRequests()

        let mine = try await openChat(try row("mine", in: viewModel), in: viewModel)
        await viewModel.destinationDidChange(from: .session(mine), to: nil).value
        await viewModel.destinationDidChange(from: nil, to: .utility(.tasks)).value
        let onPick = await viewModel.ensureServerOnPick()

        XCTAssertNil(onPick)
        XCTAssertTrue(viewModel.isServerOnPick)
        XCTAssertEqual(fake.requests, [])

        // After a foreign chat, the screen's gate adds nothing to the one return.
        let foreign = try await openChat(try row("open-1", in: viewModel), in: viewModel)
        await viewModel.destinationDidChange(from: .session(foreign), to: .utility(.tasks)).value
        let backOnPick = await viewModel.ensureServerOnPick()

        XCTAssertNil(backOnPick)
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default"])
    }

    /// A chat from another profile whose reply is still streaming keeps
    /// working after the list took the profile back: its reload follows the
    /// 409 once, one switch to the owner, and the retry succeeds.
    @MainActor
    func testAForeignChatFollowsItsSessionOnceAfterTheListTookTheProfileBack() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("open-1", profile: "opensource", at: 20, ["active_stream_id": "stream-1"])
        ])
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        let opened = try await openChat(try row("open-1", in: viewModel), in: viewModel)
        let chat = makeChat(for: opened, following: viewModel)
        // The list takes the profile back while the chat is open, as a return racing it would.
        let failure = await viewModel.ensureServerOnPick()
        XCTAssertNil(failure)
        fake.clearRequests()

        // Reattaching after backgrounding reloads the chat.
        await chat.loadMessages()

        XCTAssertNil(chat.lastError)
        XCTAssertEqual(chat.activeStreamID, "stream-1")
        XCTAssertEqual(Array(fake.requests.prefix(3)), ["GET /api/session", "POST /api/profile/switch", "GET /api/session"])
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default", "opensource"])
        XCTAssertEqual(viewModel.serverProfileName, "opensource")
        XCTAssertEqual(viewModel.activeProfileName, "default")

        // Closed, the chat can no longer take the profile from the list.
        await viewModel.destinationDidChange(from: .session(opened), to: nil).value
        do {
            _ = try await chat.client.session(id: "open-1", includeMessages: false, messageLimit: nil)
            XCTFail("Expected the profile mismatch")
        } catch let error as APIError {
            XCTAssertEqual(error.mismatchedSessionProfile, "opensource")
        }
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default", "opensource", "default"])
        XCTAssertEqual(fake.activeProfile, "default")
    }

    /// No loop: when the retry is refused too, the chat surfaces the error
    /// and switches no further.
    @MainActor
    func testAForeignChatSurfacesASecondRefusalWithoutAnotherSwitch() async throws {
        let fake = AllProfilesServerFake(
            active: "default",
            rows: [Self.webui("open-1", profile: "opensource", at: 20)],
            refusedSessionIDs: ["open-1"]
        )
        let viewModel = makeViewModel(fake)
        await viewModel.load()
        await viewModel.loadActiveProfile()
        let opened = try await openChat(try row("open-1", in: viewModel), in: viewModel)
        let chat = makeChat(for: opened, following: viewModel)
        fake.clearRequests()

        await chat.loadMessages()

        XCTAssertEqual(fake.requests, ["GET /api/session", "POST /api/profile/switch", "GET /api/session"])
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "opensource"])
        XCTAssertEqual((chat.lastError as? APIError)?.mismatchedSessionProfile, "opensource")
    }

    /// Lending a chat its own profile and taking it back is not the user's
    /// profile change: the next chat still reuses the lists the last one
    /// fetched. Picking a profile in the list is, and the next chat asks again.
    @MainActor
    func testALoanKeepsTheListsChatsReuseAndAPickExpiresThem() async throws {
        let fake = AllProfilesServerFake(active: "default", rows: [
            Self.webui("mine", profile: "default", at: 10),
            Self.webui("open-1", profile: "opensource", at: 20)
        ])
        let cache = ServerCatalogCache()
        let viewModel = SessionListViewModel(server: server, client: makeClient(fake, cache: cache))
        await viewModel.load()
        await viewModel.loadActiveProfile()
        let loader = ChatComposerConfigLoader(client: makeClient(fake, cache: cache))
        let chat = ChatComposerConfigState(currentWorkspace: "/work/default", currentProfile: "default")
        _ = await loader.loadConfiguration(from: chat)

        let opened = try await openChat(try row("open-1", in: viewModel), in: viewModel)
        await viewModel.destinationDidChange(from: .session(opened), to: nil).value
        XCTAssertEqual(fake.switchedProfiles, ["opensource", "default"])
        fake.clearRequests()
        _ = await loader.loadConfiguration(from: chat)
        // The fake keeps no cookie jar, so the list's profile read during the
        // return shares this chat's scope and the loader moves the profile
        // back; a real server's cookie keys that read to the lent profile.
        XCTAssertEqual(fake.requests.filter { $0.hasPrefix("GET ") }, ["GET /api/reasoning"],
                       "a loan and its return keep the lists fresh")

        let pick = try XCTUnwrap(viewModel.profileOptions.first { $0.normalizedName == "openai_sol" })
        let didSwitch = await viewModel.switchActiveProfile(pick)
        XCTAssertTrue(didSwitch)
        fake.clearRequests()
        _ = await loader.loadConfiguration(from: ChatComposerConfigState(currentWorkspace: "/work/openai_sol",
                                                                         currentProfile: "openai_sol"))
        XCTAssertEqual(Set(fake.requests), ["GET /api/profiles", "GET /api/models", "GET /api/workspaces",
                                            "GET /api/commands", "GET /api/reasoning"], "the pick expires them")
    }

    // MARK: - Offline cache

    @MainActor
    func testAllProfilesRowsRoundTripThroughTheCacheWithProfileAndSource() async throws {
        let context = try makeContext()
        let rows: [[String: Any]] = [
            Self.webui("d-webui", profile: "default", at: 90),
            Self.webui("o-webui", profile: "opensource", at: 80),
            Self.external("s-tg", profile: "openai_sol", source: "telegram", at: 70, [
                "source_tag": "telegram", "handoff_state": "completed", "handoff_platform": "telegram"
            ]),
            Self.external("o-wa", profile: "opensource", source: "whatsapp", at: 60)
        ]
        let fake = AllProfilesServerFake(active: "default", rows: rows)
        let liveViewModel = makeViewModel(fake)
        await liveViewModel.load(modelContext: context)
        let live = liveViewModel.sessions

        let cached = try CacheStore.cachedSessions(serverURL: server, in: context)
        XCTAssertEqual(Set(cached.compactMap(\.sessionId)), Set(rows.compactMap { $0["session_id"] as? String }),
                       "No row is dropped for not being on the active profile")

        // A cold start without the server paints from the cache alone.
        let offline = SessionListViewModel(server: server, client: makeClient { _ in throw URLError(.timedOut) })
        await offline.load(modelContext: context)

        XCTAssertTrue(offline.isViewingCachedData)
        XCTAssertEqual(offline.sessions.count, live.count)
        for session in live {
            let restored = try XCTUnwrap(offline.sessions.first { $0.sessionId == session.sessionId })
            XCTAssertEqual(restored.profile, session.profile)
            XCTAssertEqual(restored.rawSource, session.rawSource)
            XCTAssertEqual(restored.sourceTag, session.sourceTag)
            XCTAssertEqual(restored.sessionSource, session.sessionSource)
            XCTAssertEqual(restored.sourceLabel, session.sourceLabel)
            XCTAssertEqual(restored.isCliSession, session.isCliSession)
            XCTAssertEqual(restored.handoffState, session.handoffState)
            XCTAssertEqual(restored.handoffPlatform, session.handoffPlatform)
        }

        // Chips, the filter and the groups work from the cached rows.
        XCTAssertEqual(offline.profileChipLabel(for: try row("o-webui", in: offline)), "opensource")
        XCTAssertEqual(offline.profileFilterOptions, ["default", "openai_sol", "opensource"])
        let groups = offline.sessionListGroups(searchText: "", selectedProjectID: nil, profileFilter: "opensource")
        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["o-webui"])
        XCTAssertEqual(groups.messaging.map(\.platform), ["whatsapp"])
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(_ fake: AllProfilesServerFake) -> SessionListViewModel {
        SessionListViewModel(server: server, client: makeClient(fake))
    }

    /// Opens `row` the way the list does: the server moves to the row's
    /// profile, then the destination changes to its chat.
    @MainActor
    private func openChat(_ row: SessionSummary, in viewModel: SessionListViewModel) async throws -> SessionSummary {
        let opened = await viewModel.sessionForOpening(row)
        let session = try XCTUnwrap(opened)
        await viewModel.destinationDidChange(from: nil, to: .session(session)).value
        return session
    }

    /// The chat `SessionListView` shows for `session`: its client follows a
    /// 409 through the list, on the handler the list's fake installed.
    @MainActor
    private func makeChat(for session: SessionSummary, following list: SessionListViewModel) -> ChatViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: server,
            session: URLSession(configuration: configuration),
            followSessionProfile: { [list] owner in await list.followSessionProfile(owner) }
        )
        return ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: ScriptedSSEStreamingClient(),
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient()
        )
    }

    /// Loads Tasks, Skills, Memory, Insights, Archived and the Settings
    /// profile read against `fake`, as the screens reached from the list do,
    /// and asserts the server served every request under `profile`.
    @MainActor
    private func assertScreensReachedFromTheList(
        use profile: String,
        _ fake: AllProfilesServerFake,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        fake.clearRequests()
        let client = makeClient(fake)
        await TasksViewModel(server: server, client: client).load()
        await SkillsViewModel(client: client).load()
        await MemoryViewModel(server: server, client: client).load()
        await InsightsViewModel(client: client).load()
        await ArchivedSessionsViewModel(server: server, client: client).load()
        _ = try await client.profiles()

        XCTAssertFalse(fake.requests.isEmpty, file: file, line: line)
        XCTAssertFalse(fake.requests.contains("POST /api/profile/switch"), "\(fake.requests)", file: file, line: line)
        XCTAssertEqual(Set(fake.servedProfiles), [profile], "\(fake.requests)", file: file, line: line)
    }

    private func makeClient(_ fake: AllProfilesServerFake, cache: ServerCatalogCache? = nil) -> APIClient {
        makeClient(cache: cache) { try fake.handle($0) }
    }

    private func makeClient(
        cache: ServerCatalogCache? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(baseURL: server, session: URLSession(configuration: configuration), catalogCache: cache)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self, configurations: configuration)
        return ModelContext(container)
    }

    @MainActor
    private func row(_ id: String, in viewModel: SessionListViewModel) throws -> SessionSummary {
        try XCTUnwrap(viewModel.sessions.first { $0.sessionId == id }, "No row \(id)")
    }

    static func webui(
        _ id: String,
        profile: String?,
        at time: Double,
        title: String? = nil,
        _ extra: [String: Any] = [:]
    ) -> [String: Any] {
        var row: [String: Any] = [
            "session_id": id,
            "title": title ?? "Chat \(id)",
            "message_count": 4,
            "last_message_at": time,
            "session_source": "webui"
        ]
        if let profile { row["profile"] = profile }
        return row.merging(extra) { _, new in new }
    }

    static func external(
        _ id: String,
        profile: String,
        source: String,
        at time: Double,
        title: String? = nil,
        _ extra: [String: Any] = [:]
    ) -> [String: Any] {
        let isMessaging = source != "cli"
        let row: [String: Any] = [
            "session_id": id,
            "title": title ?? "\(source) \(id)",
            "message_count": 6,
            "last_message_at": time,
            "profile": profile,
            "is_cli_session": true,
            "raw_source": source,
            "session_source": isMessaging ? "messaging" : "cli",
            "source_label": source.capitalized
        ]
        return row.merging(extra) { _, new in new }
    }
}

/// The desktop app's source labels, and the handoff origin.
final class SessionSourceLabelTests: XCTestCase {
    func testSourceBadgesUseTheDesktopLabels() {
        let expected: [String: String] = [
            "api_server": "API", "bluebubbles": "iMessage", "cli": "CLI", "codex": "Codex",
            "desktop": "Desktop", "discord": "Discord", "email": "Email", "gateway": "Gateway",
            "kanban": "Kanban", "local": "Local", "matrix": "Matrix", "mattermost": "Mattermost",
            "oneshot": "One-shot", "photon": "Photon", "qqbot": "QQ", "signal": "Signal",
            "slack": "Slack", "sms": "SMS", "telegram": "Telegram", "tui": "TUI",
            "webhook": "Webhook", "weixin": "WeChat", "whatsapp": "WhatsApp", "yuanbao": "Yuanbao"
        ]

        for (id, label) in expected {
            let session = SessionSummary(sessionId: id, isCliSession: true, rawSource: id)
            XCTAssertEqual(session.sourceDisplayLabel, label, id)
        }
    }

    func testUnknownSourcesReadAsCapitalizedWords() {
        let session = SessionSummary(sessionId: "x", isCliSession: true, rawSource: "home_assistant-bridge")
        XCTAssertEqual(session.sourceDisplayLabel, "Home Assistant Bridge")
    }

    /// The server's label only restates the id ("Weixin"): the table wins. A
    /// label that says more ("Telegram Business") stays.
    func testServerLabelsDefersToTheTableOnlyWhenTheyRestateTheId() {
        let weixin = SessionSummary(
            sessionId: "wx", isCliSession: true, rawSource: "weixin", sessionSource: "messaging", sourceLabel: "Weixin"
        )
        let oneshot = SessionSummary(sessionId: "os", isCliSession: true, sourceTag: "oneshot", sourceLabel: "Oneshot")
        let apiServer = SessionSummary(sessionId: "api", isCliSession: true, rawSource: "api_server", sourceLabel: "Api Server")
        let business = SessionSummary(
            sessionId: "tb", isCliSession: true, rawSource: "telegram", sessionSource: "messaging", sourceLabel: "Telegram Business"
        )

        XCTAssertEqual(weixin.sourceDisplayLabel, "WeChat")
        XCTAssertEqual(oneshot.sourceDisplayLabel, "One-shot")
        XCTAssertEqual(apiServer.sourceDisplayLabel, "API")
        XCTAssertEqual(business.sourceDisplayLabel, "Telegram Business")
    }

    /// Messaging ids the old set missed still need the import and group per platform.
    func testDesktopMessagingIdsNeedTheImportAndGroupPerPlatform() {
        for id in ["whatsapp", "signal", "sms", "mattermost", "bluebubbles", "qqbot", "feishu", "api_server", "webhook"] {
            let session = SessionSummary(sessionId: id, rawSource: id)
            XCTAssertTrue(session.requiresExternalImport, id)
            XCTAssertEqual(session.messagingPlatform, id)
        }

        XCTAssertNil(SessionSummary(sessionId: "cli", isCliSession: true, sourceTag: "cli").messagingPlatform)
        XCTAssertNil(SessionSummary(sessionId: "web", rawSource: "telegram", sessionSource: "webui").messagingPlatform)
        XCTAssertEqual(
            SessionSummary(sessionId: "m", isCliSession: true, sessionSource: "messaging").messagingPlatform,
            "messaging"
        )
    }

    /// Forward-compatible: the WebUI list does not send handoff fields yet.
    func testCompletedHandoffFromAMessagingPlatformShowsItsOrigin() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let handedOff = try decoder.decode(SessionSummary.self, from: Data("""
        {"session_id": "h1", "session_source": "webui", "handoff_state": "completed", "handoff_platform": "telegram"}
        """.utf8))
        let pending = SessionSummary(sessionId: "h2", handoffState: "pending", handoffPlatform: "telegram")
        let local = SessionSummary(sessionId: "h3", handoffState: "completed", handoffPlatform: "cli")

        XCTAssertEqual(handedOff.handoffOriginLabel, "Telegram")
        XCTAssertNil(handedOff.sourceDisplayLabel)
        XCTAssertEqual(SessionRowView.sourceBadgeLabel(for: handedOff), "Telegram")
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: handedOff, isViewingCachedData: false),
            ["Handed off from Telegram"]
        )
        XCTAssertNil(pending.handoffOriginLabel)
        XCTAssertNil(local.handoffOriginLabel)
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(
                for: SessionSummary(sessionId: "p"),
                isViewingCachedData: false,
                profileLabel: "opensource"
            ),
            ["Profile opensource"]
        )
    }
}

/// A scripted hermes-webui for the all-profiles list. `exclude_hidden=1`
/// drops `default_hidden` rows, as upstream does. Only `/api/profile/switch`
/// moves the client's profile, and every session-scoped request for a session
/// on another profile, `GET /api/session` and the import included, gets the
/// server's 409 and is recorded as a violation. Handlers run off the test's
/// thread, so the state needs its own lock.
final class AllProfilesServerFake: @unchecked Sendable {
    private let lock = NSLock()
    private var active: String
    private let profileNames: [String]
    private let singleProfileMode: Bool
    private let honorsAllProfiles: Bool
    private var rows: [[String: Any]]
    /// Sessions the server knows but the list response leaves out.
    private let unlistedSessionIDs: Set<String>
    /// Sessions refused on every profile, as if the owner kept moving.
    private let refusedSessionIDs: Set<String>
    private let projects: [[String: Any]]
    private var recorded: [String] = []
    private var recordedProfiles: [String] = []
    private var queries: [String: [String: String]] = [:]
    private var mismatches: [String] = []
    private var switches: [String] = []
    private var newSessionProfiles: [String?] = []

    init(
        active: String,
        profiles: [String] = ["default", "opensource", "openai_sol"],
        rows: [[String: Any]],
        projects: [[String: Any]] = [],
        singleProfileMode: Bool = false,
        honorsAllProfiles: Bool = true,
        unlistedSessionIDs: Set<String> = [],
        refusedSessionIDs: Set<String> = []
    ) {
        self.active = active
        self.profileNames = profiles
        self.rows = rows
        self.unlistedSessionIDs = unlistedSessionIDs
        self.refusedSessionIDs = refusedSessionIDs
        self.projects = projects
        self.singleProfileMode = singleProfileMode
        self.honorsAllProfiles = honorsAllProfiles
    }

    var activeProfile: String { lock.withLock { active } }
    /// "METHOD /path" per request, in order.
    var requests: [String] { lock.withLock { recorded } }
    /// The cookie profile each request in `requests` was served under; a
    /// switch counts under the profile it left.
    var servedProfiles: [String] { lock.withLock { recordedProfiles } }
    var violations: [String] { lock.withLock { mismatches } }
    var switchedProfiles: [String] { lock.withLock { switches } }
    var createdSessionProfiles: [String?] { lock.withLock { newSessionProfiles } }

    func query(for path: String) -> [String: String]? { lock.withLock { queries[path] } }
    func clearRequests() { lock.withLock { recorded = []; recordedProfiles = []; mismatches = [] } }
    /// Moves the profile the way another screen would.
    func setActiveProfile(_ name: String) { lock.withLock { active = name } }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let method = request.httpMethod ?? "GET"
        let body = apiTestBodyData(from: request)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        let sessionID = query["session_id"] ?? body["session_id"] as? String

        return try lock.withLock {
            recorded.append("\(method) \(url.path)")
            recordedProfiles.append(active)
            queries[url.path] = query

            if let sessionID, let owner = profile(ofSession: sessionID),
               owner != active || refusedSessionIDs.contains(sessionID) {
                mismatches.append("\(method) \(url.path) \(sessionID) owner=\(owner) active=\(active)")
                return try respond([
                    "error": "Session belongs to a different profile",
                    "code": "session_profile_mismatch",
                    "session_id": sessionID,
                    "profile": owner
                ], to: request, status: 409)
            }

            switch (method, url.path) {
            case ("GET", "/api/sessions"):
                let allProfiles = honorsAllProfiles && query["all_profiles"] == "1"
                var listed = rows.filter { !unlistedSessionIDs.contains($0["session_id"] as? String ?? "") }
                if query["exclude_hidden"] == "1" {
                    listed = listed.filter { $0["default_hidden"] as? Bool != true }
                }
                return try respond([
                    "sessions": allProfiles ? listed : listed.filter { ($0["profile"] as? String ?? "default") == active },
                    "all_profiles": allProfiles,
                    "active_profile": active
                ], to: request)
            case ("GET", "/api/sessions/search"):
                return try respond(["sessions": [Any](), "all_profiles": honorsAllProfiles, "active_profile": active], to: request)
            case ("GET", "/api/projects"):
                return try respond(["projects": projects, "all_profiles": honorsAllProfiles, "active_profile": active], to: request)
            case ("GET", "/api/profiles"):
                return try respond([
                    "active": active,
                    "profiles": profilesJSON(),
                    "single_profile_mode": singleProfileMode
                ], to: request)
            case ("POST", "/api/profile/switch"):
                let name = try XCTUnwrap(body["name"] as? String)
                switches.append(name)
                guard profileNames.contains(name) else {
                    return try respond(["error": "Profile not found"], to: request, status: 404)
                }
                active = name
                return try respond(["active": name, "profiles": profilesJSON()], to: request)
            case ("GET", "/api/workspaces"):
                return try respond(["workspaces": [["path": "/work/\(active)"]], "last": "/work/\(active)"], to: request)
            case ("POST", "/api/session/new"):
                let requested = body["profile"] as? String
                newSessionProfiles.append(requested)
                let session: [String: Any] = [
                    "session_id": "new-\(newSessionProfiles.count)",
                    "title": "Untitled",
                    "workspace": body["workspace"] as? String ?? NSNull(),
                    "profile": requested ?? active,
                    "message_count": 0
                ]
                rows.append(session)
                return try respond(["session": session], to: request)
            case ("GET", "/api/session"), ("POST", "/api/session/import_cli"):
                let row = try XCTUnwrap(rows.first { $0["session_id"] as? String == sessionID })
                return try respond(["session": row, "imported": true], to: request)
            case ("POST", "/api/session/pin"):
                return try respond(["ok": true], to: request)
            default:
                return try respond([String: Any](), to: request)
            }
        }
    }

    private func profile(ofSession id: String) -> String? {
        guard let row = rows.first(where: { $0["session_id"] as? String == id }) else { return nil }
        return row["profile"] as? String ?? "default"
    }

    private func profilesJSON() -> [[String: Any]] {
        profileNames.map { ["name": $0, "is_default": $0 == "default", "is_active": $0 == active] }
    }

    private func respond(_ object: Any, to request: URLRequest, status: Int = 200) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: object)
        return (
            try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )),
            data
        )
    }
}
