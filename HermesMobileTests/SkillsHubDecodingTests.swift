import XCTest
@testable import HermesMobile

/// Skills Hub payloads decode from the router shapes, ignore fields a newer host adds, and
/// fall back cleanly when a field is missing.
final class SkillsHubDecodingTests: XCTestCase {
    private func json(_ text: String) throws -> BotJSON {
        try JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))
    }

    func testInstalledSkillRowsToleratesExtraAndMissingFields() throws {
        let rows = try json("""
        [
          {"name": "git-helper", "description": "Git tips", "category": "dev", "enabled": true, "usage": 4,
           "provenance": "hub", "path": "/skills/git-helper", "future": {"nested": [1, 2]}},
          {"name": "  bare  "},
          {"description": "no name"},
          "not an object"
        ]
        """).list ?? []

        let skills = rows.compactMap(DashboardSkill.init)

        XCTAssertEqual(skills.map(\.name), ["git-helper", "bare"])
        XCTAssertEqual(skills[0].provenance, "hub")
        XCTAssertTrue(skills[0].isFromHub)
        XCTAssertEqual(skills[0].category, "dev")
        XCTAssertTrue(skills[1].enabled, "A host that omits `enabled` lists enabled skills")
        XCTAssertNil(skills[1].provenance)
        XCTAssertFalse(skills[1].isFromHub, "Only a hub row can be uninstalled")
        XCTAssertNil(skills[1].description)
    }

    func testSearchDecodesResultsLockAndTimedOutSources() throws {
        let result = HubSearchResult(try json("""
        {"results": [
            {"name": "pdf-tools", "description": "PDFs", "source": "skills-sh", "identifier": "skills-sh/acme/pdf-tools",
             "trust_level": "community", "repo": "acme/skills", "tags": ["pdf", 3, ""], "stars": 9},
            {"name": "no identifier"}
          ],
         "source_counts": {"skills-sh": 1}, "timed_out": ["github"],
         "installed": {"official/dev/git-helper": {"name": "git-helper", "trust_level": "builtin", "scan_verdict": "safe",
                                                     "installed_at": "2026-09-01"}},
         "elapsed_ms": 812}
        """))

        XCTAssertEqual(result.results.map(\.identifier), ["skills-sh/acme/pdf-tools"])
        XCTAssertEqual(result.results[0].tags, ["pdf"])
        XCTAssertEqual(result.results[0].trustLevel, "community")
        XCTAssertEqual(result.timedOut, ["github"])
        XCTAssertEqual(result.installed?["official/dev/git-helper"]?.trustLevel, "builtin")
        XCTAssertEqual(result.installed?["official/dev/git-helper"]?.scanVerdict, "safe")
    }

    func testTheHostsEmptyQueryAnswerAndAMissingLockDecode() throws {
        let empty = HubSearchResult(try json(#"{"results": [], "source_counts": {}, "timed_out": [], "installed": {}}"#))
        XCTAssertEqual(empty.results, [])
        XCTAssertEqual(empty.installed, [:])

        let sparse = HubSearchResult(try json(#"{"results": [{"identifier": "x/y"}]}"#))
        XCTAssertEqual(sparse.results.first?.name, "x/y", "A result without a name shows its identifier")
        XCTAssertNil(sparse.installed, "A missing lock must not read as nothing installed")
        XCTAssertEqual(sparse.timedOut, [])
    }

    func testPreviewDecodesMarkdownAndFilesAndFallsBackToTheRequestedIdentifier() throws {
        let full = try XCTUnwrap(HubSkillPreview(try json("""
        {"name": "pdf-tools", "description": "", "source": "skills-sh", "identifier": "skills-sh/acme/pdf-tools",
         "trust_level": "community", "repo": null, "tags": [], "skill_md": "# PDF", "files": ["SKILL.md", "a.py"],
         "size_bytes": 2048}
        """), identifier: "skills-sh/acme/pdf-tools"))
        XCTAssertEqual(full.skill.name, "pdf-tools")
        XCTAssertNil(full.skill.description, "A blank description is no description")
        XCTAssertNil(full.skill.repo)
        XCTAssertEqual(full.skillMarkdown, "# PDF")
        XCTAssertEqual(full.files, ["SKILL.md", "a.py"])

        let sparse = try XCTUnwrap(HubSkillPreview(try json(#"{"name": "pdf-tools"}"#), identifier: "requested/id"))
        XCTAssertEqual(sparse.skill.identifier, "requested/id")
        XCTAssertNil(sparse.skillMarkdown)
        XCTAssertEqual(sparse.files, [])

        XCTAssertNil(HubSkillPreview(try json(#"["not", "an", "object"]"#), identifier: "requested/id"))
    }

    func testScanDecodesTheFullShapeWithExtraFields() throws {
        let scan = HubSkillScan(try json("""
        {"name": "pdf-tools", "identifier": "skills-sh/acme/pdf-tools", "source": "skills-sh", "trust_level": "community",
         "verdict": "caution", "summary": "2 findings", "policy": "block",
         "policy_reason": "Blocked (community source + caution verdict, 2 findings). Use --force to override.",
         "findings": [{"severity": "high", "category": "exfiltration", "file": "run.sh", "line": 3,
                       "description": "Posts files", "match": "curl -d"},
                      {"severity": "low", "category": "network"}],
         "severity_counts": {"critical": 0, "high": 1, "medium": 0, "low": 1, "info": 5},
         "tier1": {"passed": false, "incomplete_checks": [], "findings": [{"check": "secrets"}]},
         "scanned_at": "2026-09-25"}
        """))

        XCTAssertEqual(scan.verdict, "caution")
        XCTAssertEqual(scan.policy, .block)
        XCTAssertFalse(scan.allowsInstall)
        XCTAssertEqual(scan.findings.count, 2)
        XCTAssertEqual(scan.findings[0].line, 3)
        XCTAssertNil(scan.findings[1].file)
        XCTAssertEqual(scan.severityCounts, .init(critical: 0, high: 1, medium: 0, low: 1))
        XCTAssertEqual(scan.advisoryPassed, false)
        XCTAssertEqual(scan.advisoryFindingCount, 1)
    }

    func testScanWithFieldsMissingOrUnknownLeavesTheDecisionToTheHost() throws {
        let sparse = HubSkillScan(try json(#"{"verdict": "safe", "tier1": null}"#))
        XCTAssertNil(sparse.policy)
        XCTAssertTrue(sparse.allowsInstall, "An older host without a policy still enforces its own on install")
        XCTAssertEqual(sparse.findings, [])
        XCTAssertEqual(sparse.severityCounts.total, 0)
        XCTAssertNil(sparse.advisoryPassed)

        let ask = HubSkillScan(try json(#"{"policy": "ask"}"#))
        XCTAssertFalse(ask.allowsInstall, "The dashboard install never forces, so `ask` refuses")

        let unknown = HubSkillScan(try json(#"{"policy": "review-later"}"#))
        XCTAssertNil(unknown.policy)
    }

    func testActionStatusKeepsOnlyThisRunsLines() throws {
        let status = DashboardActionStatus(try json("""
        {"name": "skills-update", "running": false, "exit_code": 0, "pid": 7,
         "lines": ["=== skills-update started 2026-09-24 09:00:00 ===", "old run",
                   "=== skills-update started 2026-09-25 09:00:00 ===", "Updating: pdf-tools", "Updated 1 skill(s)."],
         "receipt": null}
        """))

        XCTAssertFalse(status.running)
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertEqual(status.lines, ["Updating: pdf-tools", "Updated 1 skill(s)."])
    }

    func testActionStatusWithoutAnOutcomeHasNoExitCode() throws {
        let status = DashboardActionStatus(try json(#"{"name": "skills-update", "exit_code": null}"#))

        XCTAssertFalse(status.running)
        XCTAssertNil(status.exitCode)
        XCTAssertEqual(status.lines, [])
    }

    func testHubLockEntriesSkipMalformedRowsAndReportAMissingMap() throws {
        let entries = HubLockEntry.entries(try json("""
        {"a/b": {"name": "b", "trust_level": "trusted", "scan_verdict": "safe"}, "c/d": "broken"}
        """))
        XCTAssertEqual(entries?.keys.sorted(), ["a/b"])
        XCTAssertEqual(entries?["a/b"]?.name, "b")
        XCTAssertNil(HubLockEntry.entries(.null))
    }
}
