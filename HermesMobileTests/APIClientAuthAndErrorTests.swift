import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientAuthAndErrorTests: APIClientTestCase {
    func testOnboardingPasswordValidationOnlyRequiresKnownAuthEnabledPassword() {
        XCTAssertEqual(
            OnboardingViewModel.passwordValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
                password: " \n "
            ),
            OnboardingViewModel.emptyPasswordMessage
        )
        XCTAssertNil(
            OnboardingViewModel.passwordValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
                password: "secret"
            )
        )
        XCTAssertNil(
            OnboardingViewModel.passwordValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false),
                password: ""
            )
        )
        XCTAssertNil(OnboardingViewModel.passwordValidationMessage(authStatus: nil, password: ""))
    }

    @MainActor
    func testAuthManagerConnectsToNoPasswordTailscaleServerWithoutLogin() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false))
        var requestedURLs: [URL] = []
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { url in
                requestedURLs.append(url)
                return client
            },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "100.96.12.34:9119", password: "")

        let expectedURL = try XCTUnwrap(URL(string: "http://100.96.12.34:9119"))
        XCTAssertEqual(requestedURLs, [expectedURL])
        XCTAssertEqual(client.loginPasswords, [])
        XCTAssertEqual(keychain.savedValues[.serverURL], expectedURL.absoluteString)
        XCTAssertEqual(manager.state, .loggedIn(server: expectedURL))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testServerURLNormalizationDropsAccidentalWWWBeforeWebUISubdomain() throws {
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "https://www.webui.example.test"),
            URL(string: "https://webui.example.test")
        )
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "www.webui.example.test"),
            URL(string: "https://webui.example.test")
        )
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "https://www.example.com"),
            URL(string: "https://www.example.com")
        )
    }

    @MainActor
    func testAuthManagerPreservesPasswordRequiredEmptyPasswordBehavior() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://example.test", password: "")

        XCTAssertEqual(client.loginPasswords, [])
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertEqual(manager.lastErrorMessage, OnboardingViewModel.emptyPasswordMessage)
    }

    @MainActor
    func testAuthManagerLogsInWhenPasswordIsRequired() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://example.test", password: "secret")

        let expectedURL = try XCTUnwrap(URL(string: "https://example.test"))
        XCTAssertEqual(client.loginPasswords, ["secret"])
        XCTAssertEqual(keychain.savedValues[.serverURL], expectedURL.absoluteString)
        XCTAssertEqual(manager.state, .loggedIn(server: expectedURL))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testUnauthorizedResponseThrowsUnauthorized() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )
            return (try XCTUnwrap(response), Data())
        }

        do {
            _ = try await client.sessions()
            XCTFail("Expected unauthorized error")
        } catch APIError.unauthorized {
            // Expected path.
        } catch {
            XCTFail("Expected unauthorized error, got \(error)")
        }
    }

    func testVanishedSessionResponseUsesRecoveryMessage() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            let body = Data(#"{"error":"Session not found"}"#.utf8)
            return (try XCTUnwrap(response), body)
        }

        do {
            _ = try await client.session(id: "missing-session")
            XCTFail("Expected vanished-session HTTP error")
        } catch let APIError.http(statusCode, body) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(body, #"{"error":"Session not found"}"#)
            XCTAssertEqual(
                APIError.http(statusCode: statusCode, body: body).localizedDescription,
                "That session no longer exists on the server. Reopen another session or create a new one."
            )
        } catch {
            XCTFail("Expected vanished-session HTTP error, got \(error)")
        }
    }

    func testCloudflareErrorDoesNotExposeRawHTMLBody() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 502,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )
            let body = Data("<html><title>Bad gateway</title><body>cloudflare</body></html>".utf8)
            return (try XCTUnwrap(response), body)
        }

        do {
            _ = try await client.sessions()
            XCTFail("Expected HTTP error")
        } catch let APIError.http(statusCode, body) {
            let message = APIError.http(statusCode: statusCode, body: body).localizedDescription
            XCTAssertEqual(
                message,
                "hermes-webui didn't answer. Check that it's running on the server, then try again."
            )
            XCTAssertFalse(message.contains("<html>"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("bad gateway"))
        } catch {
            XCTFail("Expected HTTP error, got \(error)")
        }
    }

    // MARK: - HTTP 403 (issue #333)

    func testForbiddenChatStartSurfacesServerReasonInsteadOfPasswordCopy() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            let body = Data(#"{"error":"Read-only imported sessions cannot be continued from WebUI"}"#.utf8)
            return (try XCTUnwrap(response), body)
        }

        do {
            _ = try await client.startChat(
                sessionID: "20260831_041231_abc",
                message: "hello",
                workspace: nil,
                model: nil
            )
            XCTFail("Expected HTTP 403 error")
        } catch let error as APIError {
            XCTAssertEqual(
                error.localizedDescription,
                "The server refused the request: Read-only imported sessions cannot be continued from WebUI"
            )
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("password"))
            XCTAssertEqual(error.privacySafeLogCategory, "http.403")
        } catch {
            XCTFail("Expected APIError, got \(error)")
        }
    }

    func testForbiddenSurfacesMessageAndDetailPayloadShapes() {
        XCTAssertEqual(
            APIError.http(statusCode: 403, body: #"{"message":"Workspace is locked"}"#).localizedDescription,
            "The server refused the request: Workspace is locked"
        )
        XCTAssertEqual(
            APIError.http(statusCode: 403, body: #"{"detail":"Not permitted"}"#).localizedDescription,
            "The server refused the request: Not permitted"
        )
    }

    func testForbiddenWithoutStructuredBodyUsesGenericFallback() {
        let fallback = "The server refused the request. Check the server permissions and try again."
        let bodies: [String?] = [
            nil,
            "",
            "   ",
            "not json",
            #"{"error":""}"#,
            "<html><title>Forbidden</title><body>cloudflare access denied</body></html>",
        ]

        for body in bodies {
            let message = APIError.http(statusCode: 403, body: body).localizedDescription
            XCTAssertEqual(message, fallback, "body: \(String(describing: body))")
            XCTAssertFalse(message.contains("<"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("password"))
        }
    }

    func testUnauthorizedAndBadRequestCopyIsUnchangedByForbiddenHandling() {
        XCTAssertEqual(
            APIError.unauthorized.localizedDescription,
            "The password was rejected. Check the server password and try again."
        )
        XCTAssertEqual(
            APIError.http(statusCode: 400, body: #"{"error":"Missing message"}"#).localizedDescription,
            "The server rejected the request: Missing message"
        )
        XCTAssertEqual(
            APIError.http(statusCode: 400, body: "<html>nope</html>").localizedDescription,
            "The server rejected the request."
        )
    }

    func testDisplayedServerMessageIsBoundedAcrossHTTPBranches() {
        let long = String(repeating: "x", count: 500)
        let body = #"{"error":"\#(long)"}"#
        let clipped = String(repeating: "x", count: 200) + "…"

        XCTAssertEqual(
            APIError.http(statusCode: 403, body: body).localizedDescription,
            "The server refused the request: \(clipped)"
        )
        XCTAssertEqual(
            APIError.http(statusCode: 400, body: body).localizedDescription,
            "The server rejected the request: \(clipped)"
        )
        XCTAssertEqual(
            APIError.http(statusCode: 418, body: body).localizedDescription,
            "Server returned HTTP 418: \(clipped)"
        )
        // The raw body is still available to callers that inspect it programmatically.
        XCTAssertEqual(APIError.http(statusCode: 403, body: body).serverMessage, long)
    }

    func testHTTPErrorPrivacySafeLogCategoryDoesNotExposeServerBody() {
        let error = APIError.http(
            statusCode: 400,
            body: #"{"error":"password=secret prompt=private raw response"}"#
        )

        let category = error.privacySafeLogCategory

        XCTAssertEqual(category, "http.400")
        XCTAssertFalse(category.contains("secret"))
        XCTAssertFalse(category.contains("private"))
        XCTAssertFalse(category.contains("raw response"))
    }

    func testNetworkErrorPrivacySafeLogCategoryUsesOnlyURLCode() {
        let error = APIError.network(underlying: URLError(.timedOut))

        XCTAssertEqual(error.privacySafeLogCategory, "network.url.-1001")
    }

    func testNetworkTimeoutUsesSetupGuidance() async throws {
        let error = APIError.network(underlying: URLError(.timedOut))

        XCTAssertEqual(
            error.localizedDescription,
            "The server did not respond in time. Check that the server is running and the connection is available."
        )
    }

    func testAppTransportSecurityErrorUsesHTTPGuidance() async throws {
        let error = APIError.network(underlying: URLError(.appTransportSecurityRequiresSecureConnection))

        XCTAssertEqual(
            error.localizedDescription,
            "iOS blocked this insecure HTTP connection. Use HTTPS, a local network address, or a Tailscale name or IP."
        )
    }

    // MARK: - Host-aware connection copy

    private static let hostAwareCodes: [URLError.Code] = [
        .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost, .timedOut,
        .badServerResponse // a default-branch code
    ]
    private static let tailscaleHosts = [
        "mac.tail123.ts.net", "MAC.TAIL123.TS.NET.", "100.64.0.1", "100.127.255.254", "100.100.100.100"
    ]
    private static let otherHosts = [
        "hermes.example.com", "localhost", "192.168.1.5", "100.63.255.255", "100.128.0.1", "ts.net",
        "evil-ts.net.example.com"
    ]

    func testTailscaleHostsGetTailscaleAdviceNamingTheHost() throws {
        for host in Self.tailscaleHosts {
            let named = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            for code in Self.hostAwareCodes {
                let message = try Self.networkError(code, failingURL: "https://\(host)/api/session").localizedDescription
                XCTAssertTrue(message.contains(named), "[\(host) \(code.rawValue)] \(message)")
                XCTAssertTrue(message.contains("Tailscale"), "[\(host) \(code.rawValue)] \(message)")
                XCTAssertFalse(message.contains("Cloudflare"), "[\(host) \(code.rawValue)] \(message)")
                XCTAssertFalse(message.localizedCaseInsensitiveContains("tunnel"), "[\(host) \(code.rawValue)] \(message)")
            }
        }
    }

    func testOtherHostsGetNeutralAdviceNamingTheHost() throws {
        for host in Self.otherHosts {
            for code in Self.hostAwareCodes {
                let message = try Self.networkError(code, failingURL: "https://\(host)/api/session").localizedDescription
                XCTAssertTrue(message.contains(host), "[\(host) \(code.rawValue)] \(message)")
                XCTAssertFalse(message.contains("Tailscale"), "[\(host) \(code.rawValue)] \(message)")
                XCTAssertFalse(message.contains("Cloudflare"), "[\(host) \(code.rawValue)] \(message)")
                XCTAssertFalse(message.localizedCaseInsensitiveContains("tunnel"), "[\(host) \(code.rawValue)] \(message)")
            }
        }
    }

    func testMissingHostGetsGenericAdvice() throws {
        for code in Self.hostAwareCodes {
            let message = try Self.networkError(code, failingURL: nil).localizedDescription
            XCTAssertFalse(message.contains("Tailscale"), "[\(code.rawValue)] \(message)")
            XCTAssertFalse(message.contains("Cloudflare"), "[\(code.rawValue)] \(message)")
            XCTAssertFalse(message.localizedCaseInsensitiveContains("tunnel"), "[\(code.rawValue)] \(message)")
        }
    }

    func testConnectionCopyIsExactForEachBranch() throws {
        let tailscale = "https://mac.tail123.ts.net"
        let other = "https://hermes.example.com"
        let rows: [(URLError.Code, String?, String)] = [
            (.cannotFindHost, tailscale, "Couldn't find mac.tail123.ts.net. Make sure Tailscale is connected on this iPhone."),
            (.cannotConnectToHost, tailscale, "Couldn't connect to mac.tail123.ts.net. Make sure Tailscale is connected on this iPhone and hermes-webui is running."),
            (.timedOut, "http://100.64.0.1:8787", "100.64.0.1 didn't respond in time. Make sure Tailscale is connected on this iPhone and the server is awake."),
            (.badServerResponse, tailscale, "Couldn't reach mac.tail123.ts.net. Make sure Tailscale is connected on this iPhone."),
            (.dnsLookupFailed, other, "Couldn't find hermes.example.com. Check the server URL and this iPhone's network."),
            (.networkConnectionLost, other, "Couldn't connect to hermes.example.com. Check that hermes-webui is running and reachable from this iPhone."),
            (.timedOut, "http://192.168.1.5:8787", "192.168.1.5 didn't respond in time. Check that the server is running and reachable from this iPhone."),
            (.badServerResponse, other, "Couldn't reach hermes.example.com. Check the server URL and this iPhone's network."),
            (.cannotFindHost, nil, "Could not find that server. Check the server URL."),
            (.cannotConnectToHost, nil, "Could not connect to the server. Check that hermes-webui is running and reachable."),
            (.timedOut, nil, "The server did not respond in time. Check that the server is running and the connection is available."),
            (.badServerResponse, nil, "Could not reach the server. Check the URL and network connection.")
        ]

        for (code, failingURL, expected) in rows {
            XCTAssertEqual(
                try Self.networkError(code, failingURL: failingURL).localizedDescription,
                expected,
                "[\(code.rawValue) \(failingURL ?? "no host")]"
            )
        }
    }

    func testTailscaleHostDetection() {
        let tailscale = [
            "mac.tail123.ts.net", "a.ts.net", "100.64.0.0", "100.64.0.1", "100.127.255.254", "100.127.255.255",
            "100.100.100.100"
        ]
        let other = [
            "ts.net", "evil-ts.net.example.com", "mac.ts.net.example.com", "100.63.255.255", "100.128.0.0",
            "100.128.0.1", "100.64.1", "100.64.0.256", "100.64.0.1.5", "100.64..1", "100.64.0.-1", "100.64.0.+1",
            "localhost", "192.168.1.5", "10.0.0.1", "fd7a:115c:a1e0::1", ""
        ]

        for host in tailscale {
            XCTAssertTrue(APIError.isTailscaleHost(host), host)
        }
        for host in other {
            XCTAssertFalse(APIError.isTailscaleHost(host), host)
        }
    }

    func testConnectionCopyNeverContainsCredentialsFromTheFailingURL() throws {
        let failingURL = "https://alice:s3cret@mac.tail123.ts.net:8443/api/session?token=abc123#frag"
        let unchangedCodes: [URLError.Code] = [
            .notConnectedToInternet, .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection, .cancelled
        ]

        for code in Self.hostAwareCodes + unchangedCodes {
            let message = try Self.networkError(code, failingURL: failingURL).localizedDescription
            if Self.hostAwareCodes.contains(code) {
                XCTAssertTrue(message.contains("mac.tail123.ts.net"), "[\(code.rawValue)] \(message)")
            }
            for secret in ["alice", "s3cret", "token", "abc123", "8443", "/api/session", "frag"] {
                XCTAssertFalse(message.contains(secret), "[\(code.rawValue)] leaks \(secret): \(message)")
            }
        }
    }

    func testGatewayErrorsBlameHermesWebUIWithoutTunnelWording() {
        for statusCode in [502, 503, 504] {
            let message = APIError.http(statusCode: statusCode, body: nil).localizedDescription
            XCTAssertEqual(message, "hermes-webui didn't answer. Check that it's running on the server, then try again.")
            XCTAssertFalse(message.localizedCaseInsensitiveContains("tunnel"))
            XCTAssertFalse(message.contains("Cloudflare"))
        }
    }

    func testUnchangedTransportCopyIgnoresTheHost() throws {
        let rows: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "This device is offline. Connect to the internet, then try again."),
            (.dataNotAllowed, "This device is offline. Connect to the internet, then try again."),
            (.secureConnectionFailed, "The HTTPS connection failed. Check the server URL and certificate."),
            (.serverCertificateUntrusted, "The HTTPS connection failed. Check the server URL and certificate."),
            (.appTransportSecurityRequiresSecureConnection, "iOS blocked this insecure HTTP connection. Use HTTPS, a local network address, or a Tailscale name or IP."),
            (.cancelled, "The request was cancelled.")
        ]

        for (code, expected) in rows {
            for failingURL in ["https://mac.tail123.ts.net", "https://hermes.example.com", nil] {
                XCTAssertEqual(
                    try Self.networkError(code, failingURL: failingURL).localizedDescription,
                    expected,
                    "[\(code.rawValue) \(failingURL ?? "no host")]"
                )
            }
        }
        XCTAssertEqual(
            APIError.network(underlying: CocoaError(.fileReadUnknown)).localizedDescription,
            "Could not reach the server. Check the URL and network connection."
        )
    }

    /// `URLSession` usually sets the failing URL itself; the client adds the
    /// request's when it is missing, so the copy can always name the host.
    func testClientNamesTheRequestHostWhenTheTransportErrorHasNoFailingURL() async throws {
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotFindHost) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://mac.tail123.ts.net")),
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.sessions()
            XCTFail("Expected a network error")
        } catch let error as APIError {
            guard case .network(let underlying) = error else {
                return XCTFail("Expected APIError.network, got \(error)")
            }
            XCTAssertEqual((underlying as? URLError)?.code, .cannotFindHost)
            XCTAssertEqual(
                error.localizedDescription,
                "Couldn't find mac.tail123.ts.net. Make sure Tailscale is connected on this iPhone."
            )
            XCTAssertEqual(error.privacySafeLogCategory, "network.url.-1003")
        }
    }

    private static func networkError(_ code: URLError.Code, failingURL: String?) throws -> APIError {
        var userInfo: [String: Any] = [:]
        if let failingURL {
            userInfo[NSURLErrorFailingURLErrorKey] = try XCTUnwrap(URL(string: failingURL))
        }
        return APIError.network(underlying: URLError(code, userInfo: userInfo))
    }
}
