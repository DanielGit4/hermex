import XCTest
@testable import HermesMobile

/// The dashboard client against scripted host responses shaped like hermes-agent's
/// `web_routers/skills.py` and `actions.py`. The host is never touched.
@MainActor final class DashboardClientTests: XCTestCase {
    override func tearDown() {
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    func testSignInRunsStatusLoginAndIdentityOnceForRequestsThatStartTogether() async throws {
        let client = DashboardHTTPFixture.client()

        async let skills = client.get(BotEndpoint.skills.url(base: DashboardHTTPFixture.host))
        async let sources = client.get(BotEndpoint.skillsHubSources.url(base: DashboardHTTPFixture.host))
        _ = try await (skills, sources)

        let calls = DashboardHTTPFixture.calls
        XCTAssertEqual(Array(calls.prefix(3)), [
            "GET https://host.example:9119/api/status",
            "POST https://host.example:9119/auth/password-login",
            "GET https://host.example:9119/api/auth/me"
        ])
        XCTAssertEqual(Set(calls.dropFirst(3)), [
            "GET https://host.example:9119/api/skills",
            "GET https://host.example:9119/api/skills/hub/sources"
        ])
        let login = DashboardHTTPFixture.body(of: "POST https://host.example:9119/auth/password-login")
        XCTAssertEqual(login["provider"].text, "basic")
        XCTAssertEqual(login["username"].text, "user")
        XCTAssertEqual(login["password"].text, "secret")
    }

    func testA401SignsInAgainAndReplaysTheRequestOnce() async throws {
        var refusals = 1
        DashboardHTTPFixture.handler = { request in
            guard request.url?.path == "/api/skills", refusals > 0 else { return nil }
            refusals -= 1
            return .json(401, .object(["detail": .string("Unauthorized")]))
        }
        let client = DashboardHTTPFixture.client()

        let skills = try await client.installedSkills()

        XCTAssertEqual(skills.map(\.name), ["git-helper", "notes", "scratchpad"])
        XCTAssertEqual(DashboardHTTPFixture.calls, [
            "GET https://host.example:9119/api/status",
            "POST https://host.example:9119/auth/password-login",
            "GET https://host.example:9119/api/auth/me",
            "GET https://host.example:9119/api/skills",
            "GET https://host.example:9119/api/status",
            "POST https://host.example:9119/auth/password-login",
            "GET https://host.example:9119/api/auth/me",
            "GET https://host.example:9119/api/skills"
        ])
    }

    func testASecond401SurfacesInsteadOfLooping() async throws {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills" ? .json(401, .null) : nil
        }
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.installedSkills()
            XCTFail("A host that keeps refusing the credential must surface it")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(401))
        }
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { $0.hasSuffix("/api/skills") }.count, 2)
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { $0.hasSuffix("/auth/password-login") }.count, 2)
    }

    func testAHostWithoutPasswordSignInIsRefusedBeforeAnyCredentialIsSent() async throws {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/status"
                ? .json(200, .object(["auth_required": .bool(false), "auth_providers": .array([])])) : nil
        }
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.installedSkills()
            XCTFail("Expected the sign-in to be refused")
        } catch {
            XCTAssertEqual(error as? BotFailure, .unsupported)
        }
        XCTAssertEqual(DashboardHTTPFixture.calls, ["GET https://host.example:9119/api/status"])
    }

    func testEachVerbSendsItsMethodAndJSONBody() async throws {
        let client = DashboardHTTPFixture.client()
        let url = DashboardHTTPFixture.host.appendingPathComponent("api/example")

        _ = try await client.post(url, body: .object(["a": .number(1)]))
        _ = try await client.put(url, body: .object(["b": .string("two")]))
        _ = try await client.patch(url, body: .object(["c": .bool(true)]))
        _ = try await client.delete(url, query: [URLQueryItem(name: "name", value: "x")])

        XCTAssertEqual(Array(DashboardHTTPFixture.calls.dropFirst(3)), [
            "POST https://host.example:9119/api/example",
            "PUT https://host.example:9119/api/example",
            "PATCH https://host.example:9119/api/example",
            "DELETE https://host.example:9119/api/example?name=x"
        ])
        XCTAssertEqual(DashboardHTTPFixture.body(of: "PUT https://host.example:9119/api/example")["b"].text, "two")
        XCTAssertEqual(DashboardHTTPFixture.body(of: "PATCH https://host.example:9119/api/example")["c"].flag, true)
    }

    func testQueryValuesAreEncodedSoURLIdentifiersSurviveTheHostsParser() {
        let url = DashboardClient.url(BotEndpoint.skillsHubPreview.url(base: DashboardHTTPFixture.host), query: [
            URLQueryItem(name: "identifier", value: "https://x.example/a+b/skill.md?x=1&y=2 z")
        ])

        XCTAssertEqual(url.absoluteString, "https://host.example:9119/api/skills/hub/preview?identifier="
                       + "https%3A%2F%2Fx.example%2Fa%2Bb%2Fskill.md%3Fx%3D1%26y%3D2%20z")
    }

    func testEachSkillsHubRouteDecodesTheRoutersShape() async throws {
        let client = DashboardHTTPFixture.client()
        let identifier = DashboardHTTPFixture.hubIdentifier

        let installed = try await client.installedSkills()
        XCTAssertEqual(installed.first { $0.name == "git-helper" }?.provenance, "hub")
        XCTAssertEqual(installed.first { $0.name == "notes" }?.enabled, false)

        let content = try await client.installedSkillContent("github")
        XCTAssertEqual(content.name, "github")
        XCTAssertEqual(content.markdown, "# GitHub\n\nUse GitHub.")
        XCTAssertEqual(content.path, "/home/hermes/skills/github/SKILL.md")

        let lock = try await client.hubLock()
        XCTAssertEqual(lock["official/dev/git-helper"]?.trustLevel, "builtin")

        let search = try await client.searchHub("pdf")
        XCTAssertEqual(search.results.map(\.identifier), [identifier])
        XCTAssertEqual(search.results.first?.trustLevel, "community")
        XCTAssertEqual(search.timedOut, ["github"])

        let preview = try await client.previewHubSkill(identifier)
        XCTAssertEqual(preview.skill.name, "pdf-tools")
        XCTAssertEqual(preview.files, ["SKILL.md", "scripts/extract.py"])

        let scan = try await client.scanHubSkill(identifier)
        XCTAssertEqual(scan.policy, .allow)
        XCTAssertEqual(scan.findings.first?.line, 12)

        let install = try await client.installHubSkill(identifier)
        XCTAssertEqual(install, "skills-install-pdf-tools-1a2b3c4d")
        let uninstall = try await client.uninstallHubSkill("git-helper")
        XCTAssertEqual(uninstall, "skills-uninstall-git-helper-5e6f7a8b")
        let update = try await client.updateHubSkills()
        XCTAssertEqual(update, "skills-update")

        let status = try await client.actionStatus(install)
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.exitCode, 0)

        XCTAssertTrue(DashboardHTTPFixture.calls.contains(
            "GET https://host.example:9119/api/skills/content?name=github"))
        XCTAssertTrue(DashboardHTTPFixture.calls.contains(
            "GET https://host.example:9119/api/skills/hub/search?q=pdf&source=all&limit=20"))
        XCTAssertTrue(DashboardHTTPFixture.calls.contains(
            "GET https://host.example:9119/api/skills/hub/scan?identifier=skills-sh%2Facme%2Fpdf-tools"))
        XCTAssertTrue(DashboardHTTPFixture.calls.contains(
            "GET https://host.example:9119/api/actions/skills-install-pdf-tools-1a2b3c4d/status"))
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST https://host.example:9119/api/skills/hub/install")["identifier"].text,
                       identifier)
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST https://host.example:9119/api/skills/hub/uninstall")["name"].text,
                       "git-helper")
        XCTAssertNil(DashboardHTTPFixture.body(of: "POST https://host.example:9119/api/skills/hub/update")["profile"].text,
                     "No profile is sent, so the host's launch profile answers")
    }

    func testANon2xxCarriesItsStatus() async throws {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills/hub/preview" ? .json(404, .object(["detail": .string("Skill not found")])) : nil
        }
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.previewHubSkill("missing/skill")
            XCTFail("Expected a 404")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(404))
        }
    }
}

/// A small stand-in for a Hermes host's dashboard: it answers the sign-in and Skills Hub
/// routes with the shapes the router source returns (plus fields a newer host might add),
/// and keeps a hub lock that install and uninstall change. `handler` returns nil to take
/// that default, so a test only writes the response it is about.
final class DashboardHTTPFixture: URLProtocol {
    enum Reply {
        case json(Int, BotJSON)
        case offline
        case timedOut
    }

    static let host = URL(string: "https://host.example:9119")!
    static let hubIdentifier = "skills-sh/acme/pdf-tools"

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply?)?
    /// The exit code actions report once finished, and how many polls they stay running.
    nonisolated(unsafe) static var actionExitCode: Int? = 0
    nonisolated(unsafe) static var pollsBeforeExit = 0
    /// A host whose install policy refuses the skill still exits 0 without installing it.
    nonisolated(unsafe) static var refusesInstall = false
    nonisolated(unsafe) private static var hubInstalled = defaultHubInstalled
    nonisolated(unsafe) private static var polls: [String: Int] = [:]
    nonisolated(unsafe) private static var recorded: [(call: String, body: BotJSON)] = []
    private static let defaultHubInstalled = ["official/dev/git-helper": "git-helper"]
    private static let lock = NSLock()

    @MainActor static func client() -> DashboardClient {
        DashboardClient(connection: BotConnection(id: UUID(), name: "Host", address: host,
                                                  username: "user", password: "secret"),
                        configuration: configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardHTTPFixture.self]
        return configuration
    }

    static var calls: [String] { lock.withLock { recorded.map(\.call) } }
    static func body(of call: String) -> BotJSON { lock.withLock { recorded.first { $0.call == call }?.body ?? .null } }
    /// The body of the latest such call, which a `handler` reads for the request it answers.
    static func lastBody(of call: String) -> BotJSON { lock.withLock { recorded.last { $0.call == call }?.body ?? .null } }
    static func calls(matching path: String) -> [String] { calls.filter { $0.contains(path) } }
    static func clearCalls() { lock.withLock { recorded = [] } }
    static func reset() {
        lock.withLock {
            handler = nil
            actionExitCode = 0
            pollsBeforeExit = 0
            refusesInstall = false
            hubInstalled = defaultHubInstalled
            polls = [:]
            recorded = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let call = "\(request.httpMethod ?? "GET") \(url.absoluteString)"
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
            data = body
        }
        let decoded = data.flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) } ?? .null
        Self.lock.withLock { Self.recorded.append((call, decoded)) }

        switch Self.handler?(request) ?? Self.lock.withLock({ Self.answer(request, body: decoded) }) {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .timedOut:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .json(let status, let value):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(value)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// The router shapes, each with an extra field a newer host might add.
    private static func answer(_ request: URLRequest, body: BotJSON) -> Reply {
        let path = request.url?.path ?? ""
        switch path {
        case "/api/status":
            return .json(200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                       "version": .string("0.21.4")]))
        case "/auth/password-login":
            return .json(200, .object(["ok": .bool(true)]))
        case "/api/auth/me":
            return .json(200, .object(["provider": .string("basic"), "username": .string("user")]))
        case "/api/skills":
            let hub = hubInstalled.values.sorted().map { name in
                skillRow(name, provenance: "hub", enabled: true)
            }
            return .json(200, .array(hub + [skillRow("notes", provenance: "bundled", enabled: false),
                                            skillRow("scratchpad", provenance: "agent", enabled: true)]))
        case "/api/skills/content":
            return .json(200, .object(["name": .string("github"),
                                       "content": .string("---\nname: github\ndescription: GitHub helpers\n---\n# GitHub\n\nUse GitHub."),
                                       "path": .string("/home/hermes/skills/github/SKILL.md")]))
        case "/api/skills/hub/sources":
            return .json(200, .object(["sources": .array([.object(["id": .string("official"), "label": .string("Official (Nous)")])]),
                                       "index_available": .bool(true), "featured": .array([]),
                                       "installed": lockMap()]))
        case "/api/skills/hub/search":
            return .json(200, .object(["results": .array([hubSkill()]), "source_counts": .object(["skills-sh": .number(1)]),
                                       "timed_out": .array([.string("github")]), "installed": lockMap()]))
        case "/api/skills/hub/preview":
            var preview = hubSkill().fields ?? [:]
            preview["skill_md"] = .string("---\nname: pdf-tools\ndescription: Work with PDFs\n---\n# PDF tools\n\nExtract text from PDFs.")
            preview["files"] = .array([.string("SKILL.md"), .string("scripts/extract.py")])
            return .json(200, .object(preview))
        case "/api/skills/hub/scan":
            return .json(200, scan(policy: "allow"))
        case "/api/skills/hub/install":
            if !refusesInstall, let identifier = body["identifier"].text {
                hubInstalled[identifier] = identifier.split(separator: "/").last.map(String.init) ?? identifier
            }
            return .json(200, .object(["ok": .bool(true), "pid": .number(4242),
                                       "name": .string("skills-install-pdf-tools-1a2b3c4d")]))
        case "/api/skills/hub/uninstall":
            let name = body["name"].text ?? ""
            hubInstalled = hubInstalled.filter { $0.value != name }
            return .json(200, .object(["ok": .bool(true), "pid": .number(4243),
                                       "name": .string("skills-uninstall-\(name)-5e6f7a8b")]))
        case "/api/skills/hub/update":
            return .json(200, .object(["ok": .bool(true), "pid": .number(4244), "name": .string("skills-update")]))
        case let path where path.hasPrefix("/api/actions/"):
            let name = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""
            let count = polls[name, default: 0]
            polls[name] = count + 1
            let running = count < pollsBeforeExit
            return .json(200, .object([
                "name": .string(name), "running": .bool(running),
                "exit_code": running ? .null : (actionExitCode.map { .number(Double($0)) } ?? .null),
                "pid": .number(4242),
                "lines": .array([.string("=== \(name) started 2026-09-24 10:00:00 ==="), .string("an earlier run"),
                                 .string("=== \(name) started 2026-09-25 10:00:00 ==="),
                                 .string(running ? "Fetching…" : "Finished \(name)")])
            ]))
        default:
            return .json(200, .object(["ok": .bool(true)]))
        }
    }

    private static func skillRow(_ name: String, provenance: String, enabled: Bool) -> BotJSON {
        .object(["name": .string(name), "description": .string("About \(name)"), "category": .string("general"),
                 "enabled": .bool(enabled), "usage": .number(3), "provenance": .string(provenance),
                 "path": .string("/home/hermes/skills/\(name)")])
    }

    private static func lockMap() -> BotJSON {
        .object(hubInstalled.mapValues { name in
            .object(["name": .string(name), "trust_level": .string(name == "git-helper" ? "builtin" : "community"),
                     "scan_verdict": .string("safe"), "install_path": .string(name)])
        })
    }

    static func hubSkill() -> BotJSON {
        .object(["name": .string("pdf-tools"), "description": .string("Work with PDFs"), "source": .string("skills-sh"),
                 "identifier": .string(hubIdentifier), "trust_level": .string("community"), "repo": .string("acme/skills"),
                 "tags": .array([.string("pdf")]), "stars": .number(12)])
    }

    static func scan(policy: String) -> BotJSON {
        .object(["name": .string("pdf-tools"), "identifier": .string(hubIdentifier), "source": .string("skills-sh"),
                 "trust_level": .string("community"), "verdict": .string(policy == "allow" ? "safe" : "caution"),
                 "summary": .string("1 low finding"), "policy": .string(policy),
                 "policy_reason": .string(policy == "allow" ? "Allowed (community source, safe verdict)"
                                          : "Blocked (community source + caution verdict, 1 findings). Use --force to override."),
                 "findings": .array([.object(["severity": .string("low"), "category": .string("network"),
                                              "file": .string("scripts/extract.py"), "line": .number(12),
                                              "description": .string("Makes an HTTP request"), "match": .string("requests.get")])]),
                 "severity_counts": .object(["critical": .number(0), "high": .number(0), "medium": .number(0), "low": .number(1)]),
                 "tier1": .null, "scanned_at": .string("2026-09-25T10:00:00Z")])
    }
}
