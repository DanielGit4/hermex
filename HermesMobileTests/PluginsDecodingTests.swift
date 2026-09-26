import XCTest
@testable import HermesMobile

/// Plugin payloads decode from the host's shapes, ignore fields a newer host adds, and fall
/// back cleanly when a field is missing or odd. No row is dropped for anything but its name.
final class PluginsDecodingTests: XCTestCase {
    private func json(_ text: String) throws -> BotJSON {
        try JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))
    }

    func testHubRowsTolerateEverySourceStatusAndMissingField() throws {
        let rows = try json("""
        [
          {"name": "memory-core", "version": "0.21.5", "description": "Memory", "source": "bundled",
           "runtime_status": "enabled", "has_dashboard_manifest": true, "dashboard_manifest": {"tab": "x"},
           "path": "/opt/hermes/plugins/memory-core", "can_remove": false, "can_update_git": false,
           "auth_required": false, "auth_command": "", "user_hidden": false, "removed_reason": null, "future": [1]},
          {"name": "notes-sync", "version": "", "description": "", "source": "user", "runtime_status": "disabled",
           "can_remove": true, "can_update_git": false, "auth_required": true, "auth_command": "hermes auth notes-sync"},
          {"name": "web/firecrawl", "source": "git", "runtime_status": "enabled", "can_remove": true, "can_update_git": true},
          {"name": "pkg-plugin", "source": "entrypoint", "runtime_status": "inactive"},
          {"name": "old-scraper", "source": "git", "runtime_status": "disabled", "removed_reason": "Malicious update (2026-08-01)"},
          {"name": "future", "source": "marketplace", "runtime_status": "quarantined"},
          {"name": "bare"},
          {"name": "  "},
          {"version": "1.0"},
          "not an object"
        ]
        """).list ?? []

        let plugins = rows.compactMap(AgentPlugin.init)

        XCTAssertEqual(plugins.map(\.name), ["memory-core", "notes-sync", "web/firecrawl", "pkg-plugin", "old-scraper", "future", "bare"])
        let bundled = plugins[0]
        XCTAssertTrue(bundled.isBundled)
        XCTAssertTrue(bundled.isEnabled)
        XCTAssertEqual(bundled.version, "0.21.5")
        XCTAssertEqual(bundled.path, "/opt/hermes/plugins/memory-core")
        XCTAssertFalse(bundled.canRemove)
        XCTAssertNil(bundled.authCommand, "An empty auth_command shows nothing")

        let user = plugins[1]
        XCTAssertNil(user.version, "An unknown version is absent, not blank")
        XCTAssertNil(user.description)
        XCTAssertTrue(user.authRequired)
        XCTAssertEqual(user.authCommand, "hermes auth notes-sync")
        XCTAssertFalse(user.isEnabled)

        XCTAssertTrue(plugins[2].canUpdateGit)
        XCTAssertEqual(PluginLabels.source(plugins[2].source), "Git")
        XCTAssertEqual(PluginLabels.source(plugins[3].source), String(localized: "Python package"))
        XCTAssertEqual(PluginLabels.status(plugins[3].runtimeStatus), String(localized: "Not enabled"))
        XCTAssertEqual(plugins[4].removedReason, "Malicious update (2026-08-01)")
        XCTAssertEqual(PluginLabels.source(plugins[5].source), "marketplace", "An unknown source shows as sent")
        XCTAssertEqual(PluginLabels.status(plugins[5].runtimeStatus), "quarantined")

        let bare = plugins[6]
        XCTAssertNil(bare.source)
        XCTAssertNil(bare.runtimeStatus)
        XCTAssertFalse(bare.canRemove)
        XCTAssertFalse(bare.canUpdateGit)
        XCTAssertFalse(bare.authRequired)
        XCTAssertEqual(PluginLabels.source(bare.source), String(localized: "Unknown source"))
    }

    func testTheCatalogDecodesEntriesRemovalsAndSparseFields() throws {
        let catalog = try XCTUnwrap(PluginCatalog(try json("""
        {"entries": [
            {"name": "touchdesigner", "repo": "https://github.com/acme/hermes-td.git",
             "sha": "0123456789abcdef0123456789abcdef01234567", "sha_short": "0123456", "description": "Control TouchDesigner.",
             "maintainer": "acme", "tier": "community", "category": "desktop", "requires_hermes": ">=0.19",
             "subdir": "plugin", "docs_url": "https://acme.example/td", "version": "1.4.0", "image": "", "screenshots": [],
             "readme": true, "onboarding": false, "platforms": ["macos", "linux"], "title": "TouchDesigner",
             "capabilities": {"provides_tools": ["td_run"], "provides_hooks": ["on_session_start"],
                              "provides_middleware": [], "requires_env": ["TD_TOKEN"], "future_kind": ["x"]},
             "capability_summary": "touchdesigner (community, maintained by acme) …",
             "installed": true, "installed_sha": "fedcba9876543210fedcba9876543210fedcba98", "update_available": true,
             "runtime_status": "enabled", "popularity": 3},
            {"name": "sparse-thing", "sha": "2222222222222222222222222222222222222222", "title": "", "capabilities": {},
             "installed": false, "installed_sha": null, "update_available": false, "runtime_status": null},
            {"name": "no-capabilities", "capabilities": null, "platforms": "linux", "docs_url": "javascript:alert(1)"},
            {"title": "No name"}
         ],
         "removed": [{"name": "bad-plugin", "repo": "https://github.com/x/bad.git", "reason": "Malicious update",
                      "date": "2026-08-01"}, {"reason": "no name"}],
         "generated_at": "2026-09-26T10:00:00Z"}
        """)))

        XCTAssertEqual(catalog.entries.map(\.name), ["touchdesigner", "sparse-thing", "no-capabilities"])
        let td = catalog.entries[0]
        XCTAssertEqual(td.displayTitle, "TouchDesigner")
        XCTAssertEqual(td.pin, "1.4.0 @ 0123456")
        XCTAssertEqual(td.subdir, "plugin")
        XCTAssertEqual(td.platforms, ["macos", "linux"])
        XCTAssertEqual(PluginLabels.platforms(td.platforms), "macOS, Linux")
        XCTAssertEqual(td.capabilities, .init(tools: ["td_run"], hooks: ["on_session_start"], middleware: [], requiredEnv: ["TD_TOKEN"]))
        XCTAssertEqual(td.docsLink?.host, "acme.example")
        XCTAssertTrue(td.installed)
        XCTAssertTrue(td.updateAvailable)
        XCTAssertEqual(td.installedSHA, "fedcba9876543210fedcba9876543210fedcba98")
        XCTAssertEqual(PluginLabels.tierNote(td.tier), String(localized:
            "Community-maintained: not written or maintained by Nous Research. Reviewed at this exact commit only."))

        let sparse = catalog.entries[1]
        XCTAssertNil(sparse.title)
        XCTAssertEqual(sparse.displayTitle, "Sparse Thing", "An empty title is derived from the name")
        XCTAssertEqual(sparse.shaShort, "2222222", "A missing sha_short comes from the full commit")
        XCTAssertEqual(sparse.pin, "2222222")
        XCTAssertEqual(sparse.capabilities, .init())
        XCTAssertNil(sparse.installedSHA)
        XCTAssertNil(sparse.runtimeStatus)
        XCTAssertEqual(PluginLabels.platforms(sparse.platforms), String(localized: "All platforms"))
        XCTAssertNil(PluginLabels.tier(sparse.tier))

        let odd = catalog.entries[2]
        XCTAssertEqual(odd.capabilities, .init())
        XCTAssertEqual(odd.platforms, [])
        XCTAssertNil(odd.docsLink, "Only an https link opens")
        XCTAssertNil(odd.pin)

        XCTAssertEqual(catalog.removed, [PluginCatalog.Removal(name: "bad-plugin", repo: "https://github.com/x/bad.git",
                                                               reason: "Malicious update", date: "2026-08-01")])
        XCTAssertNil(PluginCatalog(try json("[]")))
    }

    func testAnInstalledPluginFindsItsCatalogEntryByNameOrLeafAndARemovalByNameOrRepo() throws {
        let catalog = try XCTUnwrap(PluginCatalog(try json("""
        {"entries": [{"name": "firecrawl", "installed": true, "repo": "https://github.com/n/firecrawl.git"},
                     {"name": "voice-kit", "installed": false},
                     {"name": "legacy", "repo": "https://github.com/x/bad.git"}],
         "removed": [{"name": "bad-plugin", "repo": "https://github.com/x/bad.git", "reason": "Malicious update"}]}
        """)))

        XCTAssertEqual(catalog.entry(installedAs: "firecrawl")?.name, "firecrawl")
        XCTAssertEqual(catalog.entry(installedAs: "web/firecrawl")?.name, "firecrawl", "A nested key matches its last part")
        XCTAssertNil(catalog.entry(installedAs: "voice-kit"), "Only an installed entry is provenance")
        XCTAssertNil(catalog.entry(installedAs: "td"))
        XCTAssertEqual(catalog.removal(for: try XCTUnwrap(catalog.entry(named: "legacy")))?.reason, "Malicious update")
        XCTAssertNil(catalog.removal(for: try XCTUnwrap(catalog.entry(named: "voice-kit"))))
    }

    func testInstallAnswersDecodeLiveRestartAndNotEnabled() throws {
        let live = try XCTUnwrap(PluginInstallResult(try json("""
        {"ok": true, "plugin_name": "td", "warnings": ["Plugin requests network access."],
         "python_dependencies": ["requests>=2"], "missing_env": ["TD_TOKEN"], "enabled": true, "gateway_reloaded": true,
         "activation": {"name": "td", "key": "td", "activated_now": {}, "deferred": {"tools": ["td_run"]}, "live_now": {}},
         "restart_required": false, "install_ms": 12}
        """)))
        XCTAssertEqual(live.pluginName, "td")
        XCTAssertEqual(live.warnings, ["Plugin requests network access."])
        XCTAssertEqual(live.pythonDependencies, ["requests>=2"])
        XCTAssertEqual(live.missingEnv, ["TD_TOKEN"])
        XCTAssertEqual(live.liveness, .activeNow)

        XCTAssertEqual(PluginInstallResult(try json("""
        {"ok": true, "plugin_name": "td", "enabled": true, "gateway_reloaded": false, "restart_required": true}
        """))?.liveness, .restartRequired)
        let disabled = try XCTUnwrap(PluginInstallResult(try json("""
        {"ok": true, "plugin_name": "td", "warnings": [], "python_dependencies": [], "missing_env": [], "enabled": false,
         "gateway_reloaded": false, "activation": null, "restart_required": false}
        """)))
        XCTAssertEqual(disabled.liveness, .notEnabled)
        XCTAssertEqual(disabled.missingEnv, [])
        XCTAssertNil(PluginInstallResult(try json(#"{"ok": false, "error": "nope"}"#)))
    }

    func testAScanBlockDecodesFromTheHostsTextAndFromANewerObject() throws {
        let text = try XCTUnwrap(PluginScanBlock(.string(PluginsHTTPFixture.scanReport)))
        XCTAssertEqual(text.report, PluginsHTTPFixture.scanReport.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNil(text.verdict)
        XCTAssertEqual(text.findings, [])

        let object = try XCTUnwrap(PluginScanBlock(try json("""
        {"error": "Security scan blocked plugin install: Blocked (dangerous verdict).", "scan_blocked": true,
         "scan_verdict": "dangerous", "scan_findings": [
            {"pattern_id": "reverse_shell", "severity": "critical", "category": "exfiltration", "file": "plugin/__init__.py",
             "line": 12, "description": "Opens a reverse shell", "match": "socket.socket"},
            {"severity": "medium"}, "junk"]}
        """)))
        XCTAssertEqual(object.verdict, "dangerous")
        XCTAssertEqual(object.report, "Security scan blocked plugin install: Blocked (dangerous verdict).")
        XCTAssertEqual(object.findings.count, 2)
        XCTAssertEqual(object.findings[0], PluginScanBlock.Finding(severity: "critical", category: "exfiltration",
                                                                   patternID: "reverse_shell", file: "plugin/__init__.py",
                                                                   line: 12, description: "Opens a reverse shell"))

        XCTAssertNil(PluginScanBlock(.string("Plugin 'x' already exists.")), "Any other refusal is not a scan block")
        XCTAssertNil(PluginScanBlock(try json(#"{"error": "Dependency conflict"}"#)))
    }

    func testToggleAnswersDecode() throws {
        let enabled = try XCTUnwrap(PluginToggleResult(try json("""
        {"ok": true, "name": "td", "unchanged": false, "gateway_reloaded": true, "activation": {}, "restart_required": false}
        """)))
        XCTAssertFalse(enabled.unchanged)
        XCTAssertEqual(enabled.liveness, .activeNow)
        XCTAssertEqual(PluginToggleResult(try json("""
        {"ok": true, "name": "td", "unchanged": false, "gateway_reloaded": false, "activation": null, "restart_required": true}
        """))?.liveness, .restartRequired)
        let disabled = try XCTUnwrap(PluginToggleResult(try json(#"{"ok": true, "name": "td", "unchanged": false, "restart_required": true}"#)))
        XCTAssertFalse(disabled.unchanged)
        XCTAssertEqual(PluginToggleResult(try json(#"{"ok": true, "name": "td", "unchanged": true, "restart_required": false}"#))?.unchanged,
                       true)
        XCTAssertNil(PluginToggleResult(try json(#"{"name": "td"}"#)))
    }

    func testUpdateAnswersDecodeRepinPullAndConsent() throws {
        let repin = PluginUpdateAnswer(try json("""
        {"ok": true, "name": "web/firecrawl", "sha": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", "unchanged": false,
         "python_dependencies": ["firecrawl-py>=1"], "warnings": ["w"], "gateway_reloaded": false, "activation": null,
         "restart_required": true}
        """))
        XCTAssertEqual(repin, .updated(PluginUpdate(sha: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", output: nil, unchanged: false,
                                                    liveness: .restartRequired, warnings: ["w"],
                                                    pythonDependencies: ["firecrawl-py>=1"])))
        XCTAssertEqual(PluginUpdateAnswer(try json("""
        {"ok": true, "name": "x", "sha": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", "unchanged": true,
         "python_dependencies": [], "warnings": []}
        """)), .updated(PluginUpdate(sha: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", output: nil, unchanged: true,
                                     liveness: nil, warnings: [], pythonDependencies: [])))

        let pull = PluginUpdateAnswer(try json(#"{"ok": true, "name": "git-tool", "output": "Updating a..b\nFast-forward", "unchanged": false}"#))
        XCTAssertEqual(pull, .updated(PluginUpdate(sha: nil, output: "Updating a..b\nFast-forward", unchanged: false,
                                                   liveness: nil, warnings: [], pythonDependencies: [])))

        guard case .needsConsent(let consent)? = PluginUpdateAnswer(try json("""
        {"ok": false, "consent_required": true, "error": "Updating 'x' to 01234567 adds tools: a, b. Confirm to continue.",
         "name": "x", "sha": "0123456789abcdef0123456789abcdef01234567", "delta": {"tools": ["a", "b"]},
         "delta_lines": ["tools: a, b", "host capabilities: network"]}
        """)) else { return XCTFail("Expected a consent") }
        XCTAssertEqual(consent.deltaLines, ["tools: a, b", "host capabilities: network"])
        XCTAssertEqual(consent.shortSHA, "0123456")
        XCTAssertEqual(consent.message, "Updating 'x' to 01234567 adds tools: a, b. Confirm to continue.")

        guard case .needsConsent(let older)? = PluginUpdateAnswer(try json("""
        {"ok": false, "consent_required": true, "delta": {"tools": ["a"], "hooks": ["h"]}}
        """)) else { return XCTFail("Expected a consent") }
        XCTAssertEqual(older.deltaLines, ["hooks: h", "tools: a"], "Without delta_lines each delta still shows")

        XCTAssertNil(PluginUpdateAnswer(try json(#"{"ok": false, "error": "x"}"#)))
    }

    func testRemoveAnswersDecode() throws {
        XCTAssertEqual(PluginRemoveResult(try json(#"{"ok": true, "name": "x", "cleared_memory_provider": true}"#))?.clearedMemoryProvider,
                       true)
        XCTAssertEqual(PluginRemoveResult(try json(#"{"ok": true, "name": "x"}"#))?.clearedMemoryProvider, false)
        XCTAssertNil(PluginRemoveResult(.null))
    }

    func testTitlesFromNames() {
        XCTAssertEqual(PluginLabels.title(fromName: "voice-kit"), "Voice Kit")
        XCTAssertEqual(PluginLabels.title(fromName: "my_API_tool"), "My API Tool")
        XCTAssertEqual(PluginLabels.title(fromName: "td"), "Td")
        XCTAssertEqual(PluginLabels.title(fromName: "--"), "--")
    }
}
