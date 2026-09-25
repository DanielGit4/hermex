import XCTest
@testable import HermesMobile

/// MCP payloads decode from the router shapes, ignore fields a newer host adds, and fall
/// back cleanly when a field is missing or odd. No row is ever dropped for its `tools`.
final class MCPDecodingTests: XCTestCase {
    private func json(_ text: String) throws -> BotJSON {
        try JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))
    }

    func testServerRowsTolerateExtraMissingAndOddFields() throws {
        let rows = try json("""
        [
          {"name": "github", "transport": "stdio", "url": null, "command": "npx",
           "args": ["-y", "@modelcontextprotocol/server-github"],
           "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_...wxyz", "SHORT": "***", "EMPTY": ""},
           "auth": null, "enabled": true, "tools": {"include": ["create_issue"]}, "source": "config", "plugin": null,
           "future": {"nested": [1]}},
          {"name": "devkit-server", "transport": "http", "url": "https://mcp.example/sse", "auth": "header",
           "enabled": false, "tools": null, "source": "plugin", "plugin": "devkit"},
          {"name": "broken", "transport": "unknown", "tools": 42},
          {"name": "bare"},
          {"name": "   "},
          {"transport": "stdio"},
          "not an object"
        ]
        """).list ?? []

        let servers = rows.compactMap(MCPServer.init)

        XCTAssertEqual(servers.map(\.name), ["github", "devkit-server", "broken", "bare"])
        let github = servers[0]
        XCTAssertEqual(github.transport, "stdio")
        XCTAssertEqual(github.command, "npx")
        XCTAssertEqual(github.args, ["-y", "@modelcontextprotocol/server-github"])
        XCTAssertEqual(github.env.map(\.name), ["EMPTY", "GITHUB_PERSONAL_ACCESS_TOKEN", "SHORT"])
        XCTAssertEqual(github.env.map(\.redactedValue), ["", "ghp_...wxyz", "***"], "Redacted values show as sent")
        XCTAssertNil(github.auth)
        XCTAssertFalse(github.isFromPlugin)
        XCTAssertEqual(github.toolFilter, .include(["create_issue"]))

        let plugin = servers[1]
        XCTAssertTrue(plugin.isFromPlugin)
        XCTAssertEqual(plugin.plugin, "devkit")
        XCTAssertEqual(plugin.auth, "header")
        XCTAssertFalse(plugin.enabled)
        XCTAssertEqual(plugin.toolFilter, .all)

        XCTAssertEqual(servers[2].transport, "unknown")
        XCTAssertEqual(servers[2].toolFilter, .custom, "A tools value this build can't read never fails the row")

        let bare = servers[3]
        XCTAssertEqual(bare.transport, "unknown")
        XCTAssertTrue(bare.enabled, "A host that omits `enabled` lists an enabled server")
        XCTAssertEqual(bare.args, [])
        XCTAssertEqual(bare.env, [])
        XCTAssertFalse(bare.isFromPlugin)
    }

    func testEveryToolsShapeDecodes() throws {
        let cases: [(String, MCPToolFilter)] = [
            ("null", .all),
            (#"["a", "b"]"#, .include(["a", "b"])),
            (#"{"include": []}"#, .include([])),
            (#"{"include": "only_this"}"#, .include(["only_this"])),
            (#"{"exclude": ["x", "*_radar_*"], "prompts": false}"#, .exclude(["x", "*_radar_*"])),
            (#"{"include": ["a"], "exclude": ["b"]}"#, .include(["a"])),
            (#"{"include": null, "exclude": ["b"]}"#, .exclude(["b"])),
            (#"{"prompts": false, "resources": false}"#, .all),
            (#""garbage""#, .custom),
            ("42", .custom),
            ("[1, 2]", .custom),
            (#"{"include": 5}"#, .custom)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(MCPToolFilter(try json(text)), expected, text)
        }
    }

    func testTestResultsDecodeEachAnswer() throws {
        let connected = MCPTestResult(try json("""
        {"ok": true, "tools": [
            {"name": "create_issue", "description": "Create an issue", "schema_chars": 812},
            {"name": "list_issues", "description": ""},
            {"description": "no name"}
         ], "prompts": 2, "resources": 1, "elapsed_ms": 300}
        """))
        guard case .connected(let tools, let prompts, let resources)? = connected else {
            return XCTFail("Expected a connected result")
        }
        XCTAssertEqual(tools.map(\.name), ["create_issue", "list_issues"])
        XCTAssertEqual(tools[0].schemaCharacters, 812)
        XCTAssertNil(tools[1].schemaCharacters, "schema_chars is optional per tool")
        XCTAssertNil(tools[1].description)
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(resources, 1)

        XCTAssertEqual(MCPTestResult(try json(#"{"ok": true, "tools": []}"#)),
                       .connected(tools: [], prompts: 0, resources: 0))
        XCTAssertEqual(MCPTestResult(try json(#"{"ok": false, "error": "OAuth authentication required — no token found.", "tools": []}"#)),
                       .failed(error: "OAuth authentication required — no token found."))
        XCTAssertEqual(MCPTestResult(try json(#"{"ok": false}"#)), .failed(error: nil))
        XCTAssertNil(MCPTestResult(try json(#"{"tools": []}"#)), "Without `ok` the host has not said it connected")
        XCTAssertNil(MCPTestResult(.null))
    }

    func testTheCatalogDecodesEntriesAndDiagnostics() throws {
        let catalog = try XCTUnwrap(MCPCatalog(try json("""
        {"entries": [
            {"name": "blender-mcp", "description": "Drive Blender.", "source": "https://github.com/ahujasid/blender-mcp",
             "transport": "stdio", "auth_type": "none", "required_env": [],
             "command": "${INSTALL_DIR}/.venv/bin/blender-mcp", "args": ["--port", "9876"], "url": null,
             "install_url": "https://github.com/ahujasid/blender-mcp.git", "install_ref": "v1.2.0",
             "bootstrap": ["uv venv .venv", "uv pip install -e ."], "default_enabled": ["get_scene_info"],
             "post_install": "Open Blender.", "suggest": null, "needs_install": true, "installed": true, "enabled": false,
             "detected_apps": []},
            {"name": "brave-search", "transport": "stdio", "auth_type": "api_key",
             "required_env": [{"name": "BRAVE_API_KEY", "prompt": "API key", "required": true},
                              {"name": "BRAVE_REGION", "prompt": "Region", "required": false},
                              {"name": "LEGACY_KEY", "prompt": "Defaults to required"},
                              {"name": "BRAVE_API_KEY", "prompt": "duplicate"},
                              {"prompt": "no name"}],
             "command": "npx", "args": ["-y", "@brave/brave-search-mcp-server"], "post_install": ""},
            {"name": "sparse"},
            {"description": "no name"}
         ],
         "diagnostics": [{"name": "future-thing", "kind": "future_manifest", "message": "needs a newer Hermes"},
                         {"kind": "invalid"}]}
        """)))

        XCTAssertEqual(catalog.entries.map(\.name), ["blender-mcp", "brave-search", "sparse"])
        let git = catalog.entries[0]
        XCTAssertTrue(git.needsInstall)
        XCTAssertEqual(git.installURL, "https://github.com/ahujasid/blender-mcp.git")
        XCTAssertEqual(git.installRef, "v1.2.0")
        XCTAssertEqual(git.bootstrap, ["uv venv .venv", "uv pip install -e ."])
        XCTAssertEqual(git.command, "${INSTALL_DIR}/.venv/bin/blender-mcp")
        XCTAssertEqual(git.args, ["--port", "9876"])
        XCTAssertEqual(git.postInstall, "Open Blender.")
        XCTAssertEqual(git.sourceURL?.host, "github.com")
        XCTAssertTrue(git.installed)
        XCTAssertFalse(git.enabled)

        let apiKey = catalog.entries[1]
        XCTAssertEqual(apiKey.requiredEnv.map(\.name), ["BRAVE_API_KEY", "BRAVE_REGION", "LEGACY_KEY"])
        XCTAssertEqual(apiKey.requiredEnv.map(\.isRequired), [true, false, true])
        XCTAssertNil(apiKey.postInstall, "An empty post_install shows nothing")

        let sparse = catalog.entries[2]
        XCTAssertNil(sparse.transport)
        XCTAssertNil(sparse.source)
        XCTAssertNil(sparse.sourceURL)
        XCTAssertFalse(sparse.needsInstall)
        XCTAssertFalse(sparse.installed)
        XCTAssertEqual(sparse.requiredEnv, [])

        XCTAssertEqual(catalog.diagnostics, [
            MCPCatalog.Diagnostic(name: "future-thing", kind: "future_manifest", message: "needs a newer Hermes")
        ])
    }

    func testAnInternalCatalogFailureIsAnEmptyCatalog() throws {
        let catalog = try XCTUnwrap(MCPCatalog(try json(#"{"entries": [], "diagnostics": []}"#)))
        XCTAssertEqual(catalog.entries, [])
        XCTAssertNil(MCPCatalog(try json("[]")))
    }

    func testANonWebSourceIsNotALink() throws {
        let entry = try XCTUnwrap(MCPCatalogEntry(try json(#"{"name": "x", "source": "javascript:alert(1)"}"#)))
        XCTAssertEqual(entry.source, "javascript:alert(1)")
        XCTAssertNil(entry.sourceURL)
    }

    func testInstallAnswersDecode() throws {
        XCTAssertEqual(MCPInstallStart(try json(#"{"ok": true, "name": "airtable", "background": false}"#)), .finished)
        XCTAssertEqual(MCPInstallStart(try json(#"{"ok": true, "name": "airtable"}"#)), .finished)
        XCTAssertEqual(MCPInstallStart(try json("""
        {"ok": true, "name": "blender-mcp", "background": true, "action": "mcp-install-blender-mcp-1a2b3c4d", "pid": 7}
        """)), .background(action: "mcp-install-blender-mcp-1a2b3c4d"))
        XCTAssertNil(MCPInstallStart(try json(#"{"ok": true, "background": true}"#)),
                     "A background install without an action can't be followed")
        XCTAssertNil(MCPInstallStart(try json(#"{"ok": false}"#)))
    }
}
