import XCTest
@testable import HermesMobile

/// Adding an MCP server by hand against `MCPHTTPFixture`, which plays the host's
/// `POST /api/mcp/servers` rules (hermes-agent `web_routers/mcp.py`). The device-owner check is
/// injected and nothing sleeps. Every secret here is an obviously fake fixture.
@MainActor final class MCPAddServerTests: XCTestCase {
    private let host = "https://host.example:9119"
    private let profile = "hermex-dev"
    private let token = "fake-bearer-token-0000"
    private let envValue = "fake-env-value-1234"

    override func setUp() {
        super.setUp()
        MCPHTTPFixture.activate()
    }

    override func tearDown() {
        MCPHTTPFixture.reset()
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    // MARK: - Request body

    func testEachModeSendsExactlyTheHostsBodyWithTheProfileInTheQueryOnly() async throws {
        let cases: [(MCPServerDraft, BotJSON)] = [
            (urlDraft(" remote ", url: " https://mcp.example.com/mcp "), .object([
                "name": .string("remote"), "url": .string("https://mcp.example.com/mcp"), "auth": .string("none")
            ])),
            (urlDraft("with-token", auth: .bearer, token: "  \(token)  "), .object([
                "name": .string("with-token"), "url": .string("https://mcp.example.com/mcp"), "auth": .string("header"),
                "bearer_token": .string(token)
            ])),
            (urlDraft("signs-in", auth: .oauth), .object([
                "name": .string("signs-in"), "url": .string("https://mcp.example.com/mcp"), "auth": .string("oauth")
            ])),
            (commandDraft("local", command: " npx ", args: ["-y", "", "   ", "@scope/server name"],
                          env: [("API_KEY", envValue), ("", ""), (" REGION ", " eu ")]), .object([
                "name": .string("local"), "command": .string("npx"),
                "args": .array([.string("-y"), .string("@scope/server name")]),
                "env": .object(["API_KEY": .string(envValue), "REGION": .string("eu")])
            ]))
        ]
        for (draft, expected) in cases {
            DashboardHTTPFixture.clearCalls()
            let (model, _) = makeModels()
            model.draft = draft

            await model.submit()

            guard case .added = model.phase else {
                XCTFail("\(draft.trimmedName) wasn't added: \(model.phase)")
                continue
            }
            let posts = addRequests()
            XCTAssertEqual(posts.count, 1, draft.trimmedName)
            XCTAssertEqual(posts.first?.body, expected, draft.trimmedName)
            XCTAssertEqual(posts.first?.query, "profile=\(profile)", draft.trimmedName)
            XCTAssertNil(posts.first?.body.fields?["profile"], "The profile is never in the body")
        }
    }

    func testACommandAlwaysSendsArgsAndEnvAndNothingOfTheURLMode() {
        var draft = commandDraft("bare")
        draft.url = "https://left.example"
        draft.auth = .bearer
        draft.bearerToken = token

        XCTAssertEqual(draft.body, .object([
            "name": .string("bare"), "command": .string("npx"), "args": .array([]), "env": .object([:])
        ]))
    }

    func testSecretsTypedForAnotherModeAreNeverSent() async throws {
        var draft = urlDraft("switcher", auth: .bearer, token: token)
        draft.command = "npx"
        draft.args = [MCPServerDraft.Argument(value: "-y")]
        draft.env = [MCPServerDraft.EnvEntry(name: "API_KEY", value: envValue)]
        let url = BotJSON.string("https://mcp.example.com/mcp")

        draft.auth = .oauth
        XCTAssertEqual(draft.body, .object(["name": .string("switcher"), "url": url, "auth": .string("oauth")]))
        XCTAssertFalse(draft.hasSecrets)
        draft.auth = .none
        XCTAssertEqual(draft.body, .object(["name": .string("switcher"), "url": url, "auth": .string("none")]))
        XCTAssertFalse(draft.hasSecrets)
        draft.mode = .command
        draft.env = []
        XCTAssertEqual(draft.body, .object([
            "name": .string("switcher"), "command": .string("npx"), "args": .array([.string("-y")]), "env": .object([:])
        ]))
        XCTAssertFalse(draft.hasSecrets)

        // Sent as OAuth, the token typed earlier is neither sent, asked about, nor kept.
        draft.mode = .url
        draft.auth = .oauth
        var prompts = 0
        let (model, _) = makeModels(authenticate: { _ in
            prompts += 1
            return .confirmed
        })
        model.draft = draft
        await model.submit()

        XCTAssertNil(addRequests().first?.body.fields?["bearer_token"])
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(model.draft.bearerToken, "")
        XCTAssertFalse(model.secretsWereCleared, "Nothing secret was sent")
    }

    // MARK: - Problems

    func testProblemsMirrorTheHostsRulesInFormOrder() {
        var draft = MCPServerDraft()
        XCTAssertEqual(draft.problem, .nameRequired)
        draft.name = "   "
        XCTAssertEqual(draft.problem, .nameRequired)
        draft.name = "team/files"
        XCTAssertEqual(draft.problem, .nameHasSlash, "Such a server couldn't be tested or deleted by path")
        draft.name = "files"
        XCTAssertEqual(draft.problem, .urlInvalid, "A URL is required")
        for bad in ["ftp://files.example", "files.example/mcp", "https://", "mailto:someone@files.example"] {
            draft.url = bad
            XCTAssertEqual(draft.problem, .urlInvalid, bad)
        }
        for good in ["https://files.example/mcp", "http://localhost:8080/sse", "  HTTPS://Files.example  "] {
            draft.url = good
            XCTAssertNil(draft.problem, good)
        }

        draft.auth = .bearer
        for missing in ["", "   ", "Bearer ", "bearer", "BEARER    "] {
            draft.bearerToken = missing
            XCTAssertEqual(draft.problem, .tokenRequired, "“\(missing)”")
        }
        draft.bearerToken = "Bearer \(token)"
        XCTAssertNil(draft.problem, "The host strips a pasted prefix")

        draft.mode = .command
        XCTAssertEqual(draft.problem, .commandRequired)
        draft.command = "npx"
        XCTAssertNil(draft.problem, "The URL mode's fields don't block a command")
        for env in [[("", "x")], [("1KEY", "x")], [("MY-KEY", "x")], [("A", "1"), (" A ", "2")]] {
            draft.env = env.map { MCPServerDraft.EnvEntry(name: $0.0, value: $0.1) }
            XCTAssertEqual(draft.problem, .envNames, env.map(\.0).joined(separator: ","))
        }
        draft.env = [MCPServerDraft.EnvEntry(), MCPServerDraft.EnvEntry(name: "_OK_1", value: "")]
        XCTAssertNil(draft.problem, "A blank row is dropped and an empty value is allowed")
        XCTAssertFalse(MCPServerDraft.Problem.envNames.message.isEmpty)
    }

    // MARK: - Device owner

    func testFaceIDIsAskedOnceAndOnlyWhenSecretsAreSent() async {
        let cases: [(MCPServerDraft, Int)] = [
            (urlDraft("with-token", auth: .bearer, token: token), 1),
            (commandDraft("with-env", env: [("API_KEY", envValue)]), 1),
            (urlDraft("plain"), 0),
            (urlDraft("signs-in", auth: .oauth), 0),
            (commandDraft("no-env", args: ["-y"]), 0)
        ]
        for (draft, expected) in cases {
            var reasons: [String] = []
            let (model, _) = makeModels(authenticate: { reason in
                reasons.append(reason)
                return .confirmed
            })
            model.draft = draft

            await model.submit()

            XCTAssertEqual(reasons.count, expected, draft.trimmedName)
            XCTAssertTrue(reasons.allSatisfy { $0.contains(draft.trimmedName) }, draft.trimmedName)
            guard case .added = model.phase else { return XCTFail("\(draft.trimmedName) wasn't added") }
        }
    }

    func testACancelledOrUnavailableCheckSendsNothingAndKeepsTheSecrets() async {
        var outcome = DeviceOwnerAuthentication.Outcome.cancelled
        let (model, _) = makeModels(authenticate: { _ in outcome })
        var draft = commandDraft("with-env", env: [("API_KEY", envValue)])
        model.draft = draft

        await model.submit()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.draft, draft, "Cancelling keeps every field, secrets included")
        XCTAssertNil(model.authenticationProblem)
        XCTAssertFalse(model.secretsWereCleared)
        XCTAssertEqual(DashboardHTTPFixture.calls, [], "Cancelling sends nothing, not even a sign-in")

        outcome = .unavailable("Set a passcode on this iPhone to confirm this change.")
        draft = urlDraft("with-token", auth: .bearer, token: token)
        model.draft = draft
        await model.submit()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.authenticationProblem, "Set a passcode on this iPhone to confirm this change.")
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(DashboardHTTPFixture.calls, [])
    }

    // MARK: - Success

    func testSuccessShowsTheHostsSummaryAddsTheRowAndReloadsTheList() async throws {
        let (model, servers) = makeModels()
        await servers.load()
        await servers.test("kit")
        XCTAssertNotNil(servers.tests["kit"], "An unknown server's failed test")
        model.draft = commandDraft("kit", args: ["-y", "@scope/kit"], env: [("API_KEY", envValue), ("REGION", "eu")])
        var during: (phase: MCPAddServerViewModel.Phase, values: [String])?
        MCPHTTPFixture.activate { request in
            if Self.isAdd(request) { during = readOnMain { (model.phase, model.draft.env.map(\.value)) } }
            return nil
        }
        DashboardHTTPFixture.clearCalls()

        await model.submit()

        guard case .added(let row) = model.phase else { return XCTFail("Expected success, got \(model.phase)") }
        XCTAssertEqual(during?.phase, .sending)
        XCTAssertEqual(during?.values, ["", ""], "The secrets are gone before the request is awaited")
        XCTAssertEqual(row.name, "kit")
        XCTAssertEqual(row.command, "npx")
        XCTAssertEqual(row.args, ["-y", "@scope/kit"])
        XCTAssertEqual(row.env.map(\.name), ["API_KEY", "REGION"])
        XCTAssertEqual(row.env.map(\.redactedValue), ["fake...1234", "***"], "The host's masked values")
        XCTAssertEqual(servers.servers.map(\.name), ["dev-tools", "github", "kit", "linear", "odd one"])
        XCTAssertEqual(servers.server(named: "kit"), row)
        XCTAssertNil(servers.tests["kit"], "A stale result under the same name is dropped")
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/servers"), [
            "POST \(host)/api/mcp/servers?profile=\(profile)",
            "GET \(host)/api/mcp/servers?profile=\(profile)"
        ])
        XCTAssertFalse(model.needsSignIn)
        XCTAssertEqual(model.draft.env.map(\.name), ["API_KEY", "REGION"], "Names stay")
    }

    func testAFailedReloadKeepsTheAddedRowAndTheSuccess() async throws {
        let (model, servers) = makeModels()
        await servers.load()
        MCPHTTPFixture.activate { request in
            request.httpMethod == "GET" && request.url?.path == "/api/mcp/servers"
                ? .json(500, .object(["detail": .string("boom")])) : nil
        }
        model.draft = urlDraft("remote", auth: .oauth)

        await model.submit()

        guard case .added(let row) = model.phase else { return XCTFail("Expected success, got \(model.phase)") }
        XCTAssertEqual(row.auth, "oauth")
        XCTAssertEqual(servers.servers.map(\.name), ["dev-tools", "github", "linear", "odd one", "remote"])
        XCTAssertEqual(servers.server(named: "remote"), row)
        guard case .failed = servers.listState else { return XCTFail("The failed reload shows on the list") }
    }

    func testOnlyAnOAuthServerAsksForASignInNext() async throws {
        let cases: [(MCPServerDraft, String?, Bool)] = [
            (urlDraft("signs-in", auth: .oauth), "oauth", true),
            (urlDraft("with-token", auth: .bearer, token: token), "header", false),
            (urlDraft("plain"), nil, false)
        ]
        for (draft, auth, signIn) in cases {
            let (model, _) = makeModels()
            model.draft = draft

            await model.submit()

            guard case .added(let row) = model.phase else { return XCTFail("\(draft.trimmedName) wasn't added") }
            XCTAssertEqual(row.auth, auth, draft.trimmedName)
            XCTAssertEqual(model.needsSignIn, signIn, draft.trimmedName)
        }
    }

    // MARK: - Failures

    func testRefusalsShowTheHostsDetailVerbatim() async {
        var reply: DashboardHTTPFixture.Reply?
        MCPHTTPFixture.activate { request in Self.isAdd(request) ? reply : nil }
        let cases: [(MCPServerDraft, DashboardHTTPFixture.Reply?, String)] = [
            (commandDraft("github"), nil, "Server 'github' already exists"),
            (commandDraft("dev-tools"), nil, "Server 'dev-tools' is provided by plugin 'devkit' and cannot be modified"),
            (commandDraft("local"), .json(400, .object(["detail": .string("Provide exactly one of URL (HTTP/SSE) or command (stdio)")])),
             "Provide exactly one of URL (HTTP/SSE) or command (stdio)"),
            (commandDraft("local", command: "bash"),
             .json(400, .object(["detail": .string("Server 'local' rejected: suspicious command/args configuration")])),
             "Server 'local' rejected: suspicious command/args configuration")
        ]
        for (draft, answer, detail) in cases {
            reply = answer
            let (model, servers) = makeModels()
            model.draft = draft

            await model.submit()

            XCTAssertEqual(model.phase, .failed(detail), "No prefix, no rewording")
            XCTAssertNil(servers.server(named: draft.trimmedName), "A failed add changes nothing")
        }
    }

    func testARefusalWithoutADetailSaysTheHostRefused() async {
        var status = 400
        MCPHTTPFixture.activate { request in Self.isAdd(request) ? .json(status, .object([:])) : nil }
        for code in [400, 409] {
            status = code
            let (model, _) = makeModels()
            model.draft = urlDraft("files")

            await model.submit()

            XCTAssertEqual(model.phase, .failed(String(localized: "Your Hermes host refused to add “files”.")), "\(code)")
        }
    }

    func testNothingButTheServersSummaryIsSuccess() async {
        var reply = DashboardHTTPFixture.Reply.json(500, .object(["detail": .string("boom")]))
        MCPHTTPFixture.activate { request in Self.isAdd(request) ? reply : nil }
        let cases: [(DashboardHTTPFixture.Reply, String)] = [
            (.json(500, .object(["detail": .string("boom")])), "500"),
            (.timedOut, PluginRequest.lostContact),
            (.json(502, .object([:])), PluginRequest.lostContact),
            (.json(200, .object([:])), PluginRequest.lostContact),
            (.json(200, MCPHTTPFixture.serverRow("other", transport: "http", url: "https://mcp.example.com/mcp")),
             PluginRequest.lostContact)
        ]
        for (answer, expected) in cases {
            reply = answer
            let (model, servers) = makeModels()
            model.draft = urlDraft("files")

            await model.submit()

            guard case .failed(let message) = model.phase else { return XCTFail("\(answer) must not succeed") }
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertNil(servers.server(named: "files"))
            XCTAssertFalse(model.needsSignIn)
        }
    }

    func testAnOfflinePhoneNeverSendsTheServer() async {
        MCPHTTPFixture.activate { _ in .offline }
        let (model, _) = makeModels()
        model.draft = urlDraft("with-token", auth: .bearer, token: token)

        await model.submit()

        XCTAssertEqual(model.phase, .failed(DashboardProblem(URLError(.notConnectedToInternet)).message))
        XCTAssertEqual(addRequests().count, 0)
        XCTAssertEqual(DashboardHTTPFixture.calls, ["GET \(host)/api/status"], "Only the sign-in was tried")
        XCTAssertEqual(model.draft.bearerToken, "", "Cleared all the same")
    }

    // MARK: - Secrets

    func testSecretsAreEmptyAfterEverySubmitWhateverTheOutcome() async {
        let outcomes: [(String, DashboardHTTPFixture.Reply?)] = [
            ("success", nil),
            ("refused", .json(400, .object(["detail": .string("Server 'x' rejected: suspicious command/args configuration")]))),
            ("conflict", .json(409, .object(["detail": .string("Server 'x' already exists")]))),
            ("broken", .json(500, .object([:]))),
            ("timeout", .timedOut)
        ]
        for (label, reply) in outcomes {
            MCPHTTPFixture.activate { request in Self.isAdd(request) ? reply : nil }
            for draft in [urlDraft("token-\(label)", auth: .bearer, token: token),
                          commandDraft("env-\(label)", env: [("API_KEY", envValue), ("REGION", "eu")])] {
                let (model, _) = makeModels()
                model.draft = draft

                await model.submit()

                XCTAssertNotEqual(model.phase, .sending, label)
                XCTAssertNotEqual(model.phase, .editing, label)
                XCTAssertEqual(model.draft.bearerToken, "", label)
                XCTAssertEqual(model.draft.env.map(\.value), draft.env.map { _ in "" }, label)
                XCTAssertEqual(model.draft.env.map(\.name), draft.env.map(\.name), "\(label): names stay")
                XCTAssertTrue(model.secretsWereCleared, label)
            }
        }
    }

    func testAFailedSubmitKeepsTheFormAndAsksForTheSecretsAgain() async {
        let (model, _) = makeModels()
        model.draft = urlDraft("github", auth: .bearer, token: token)

        await model.submit()

        XCTAssertEqual(model.phase, .failed("Server 'github' already exists"))
        XCTAssertEqual([model.draft.name, model.draft.url], ["github", "https://mcp.example.com/mcp"])
        XCTAssertEqual(model.draft.auth, .bearer)
        XCTAssertEqual(model.draft.problem, .tokenRequired)
        XCTAssertFalse(model.canSubmit)

        model.draft.name = "github-2"
        model.draft.bearerToken = token
        XCTAssertFalse(model.canSubmit, "Cleared secrets are reviewed again first")
        model.beginReview()
        XCTAssertEqual(model.phase, .editing)
        XCTAssertFalse(model.secretsWereCleared)
        await model.submit()

        guard case .added(let row) = model.phase else { return XCTFail("Expected success, got \(model.phase)") }
        XCTAssertEqual(row.name, "github-2")
    }

    // MARK: - Helpers

    private func makeModels(
        authenticate: @escaping @MainActor (String) async -> DeviceOwnerAuthentication.Outcome = { _ in .confirmed }
    ) -> (MCPAddServerViewModel, MCPServersViewModel) {
        let client = DashboardHTTPFixture.client()
        let servers = MCPServersViewModel(client: client, profile: profile)
        return (MCPAddServerViewModel(client: client, servers: servers, authenticate: authenticate), servers)
    }

    private func urlDraft(_ name: String, url: String = "https://mcp.example.com/mcp",
                          auth: MCPServerDraft.Auth = .none, token: String = "") -> MCPServerDraft {
        var draft = MCPServerDraft()
        draft.name = name
        draft.url = url
        draft.auth = auth
        draft.bearerToken = token
        return draft
    }

    private func commandDraft(_ name: String, command: String = "npx", args: [String] = [],
                              env: [(String, String)] = []) -> MCPServerDraft {
        var draft = MCPServerDraft()
        draft.mode = .command
        draft.name = name
        draft.command = command
        draft.args = args.map { MCPServerDraft.Argument(value: $0) }
        draft.env = env.map { MCPServerDraft.EnvEntry(name: $0.0, value: $0.1) }
        return draft
    }

    /// Every add request so far, with its raw query.
    private func addRequests() -> [(query: String?, body: BotJSON)] {
        DashboardHTTPFixture.requests.compactMap { call, body in
            guard call.hasPrefix("POST "), let components = URLComponents(string: String(call.dropFirst(5))),
                  components.path == "/api/mcp/servers" else { return nil }
            return (components.percentEncodedQuery, body)
        }
    }

    private nonisolated static func isAdd(_ request: URLRequest) -> Bool {
        request.httpMethod == "POST" && request.url?.path == "/api/mcp/servers"
    }
}
