# Daniel's fork (`DanielGit4/hermex`)

This fork extends Hermex so the iPhone mirrors the Hermes **dashboard**: install and
manage skills, MCP servers, plugins, config, env keys, logs and the gateway. It is
developed by Hermes Kanban cards worked by Claude Code. Read this file together with
`AGENTS.md`; where they conflict for fork work, this file wins.

## Branches and remotes

- `origin` = `DanielGit4/hermex` (push here). `upstream` = `uzairansaruzi/hermex`
  (fetch only; push is disabled).
- `master` mirrors `upstream/master` and is never edited by hand.
- `daniel/main` is the fork's release branch and the base of every card branch.
- Card branches: `hermex/<task-id>-<slug>` (set by the Hermes project), one PR into `daniel/main` per card.
- Upstream sync: `.github/workflows/upstream-sync.yml` fast-forwards `master` weekly;
  the Hermes cron job "hermex upstream sync" opens the `master → daniel/main` PR.
  A conflicting sync becomes a Kanban card.

## Identity and signing

- Bundle ID `com.danielgit4.hermexdev`, app group `group.com.danielgit4.hermexdev`,
  set by the gitignored `Config/Local.xcconfig`. Never use `com.uzairansar.*` IDs,
  never edit `Config/Shared.xcconfig` identity lines, never touch the maintainer's
  TestFlight scripts (`scripts/branch-testflight`, release workflow).
- Simulator work needs no Apple team. Device installs use Daniel's free Personal Team
  `7LGYLP323F` (set in `Config/Local.xcconfig`) through `scripts/fork-install-device`,
  which layers `Config/ForkPersonalTeam.xcconfig`: the main app signs with
  `Config/HermesMobile.personal-team.entitlements` (no `aps-environment`, because
  Personal Teams cannot sign Push). Those builds expire after 7 days. Once Daniel's own
  Apple Developer Program membership exists: TestFlight via
  `.github/workflows/fork-testflight.yml` (disabled until secrets are set), with push.
- `scripts/fork-install-device` builds the Debug configuration with the Swift optimizer
  on (`SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
  GCC_OPTIMIZATION_LEVEL=s`), so the phone runs the fast app while the bundle ID,
  signing, entitlements and DEBUG-only tools (Streaming Lab) stay the same. It takes a
  few minutes longer. `scripts/fork-install-device --debug` builds today's unoptimized
  (`-Onone`) app: use it to step through code or inspect variables in Xcode's debugger,
  or to check whether a phone-only bug comes from the optimizer.
- Lanes never run `fork-install-device` and never use `-allowProvisioningUpdates`;
  device installs are Daniel's step.
- `scripts/test-sim` needs `HERMEX_BUNDLE_ID=com.danielgit4.hermexdev`.
- Lane simulator: iPhone 17 Pro, iOS 26.5, `78BE6C32-D801-4009-9CF2-BFD31EA02B87`.
  The main checkout uses iPhone 17 `21D71958-8B13-4CE6-BCF2-709933E0D3C8`.

## Product decisions (settled with Daniel, 2026-09-25)

- **Backend:** new screens talk to the **Hermes dashboard REST API** (hermes-agent
  `hermes_cli/web_routers/*.py`), not hermes-webui. Reuse the saved Bot connection
  and its HTTP sign-in (`BotDashboardClient.signIn`, `auth/password-login`, cookie
  session). Do not add hermes-webui routes.
- **Placement:** one new utility destination **Dashboard** (`SessionListUtilityDestination.dashboard`)
  next to Skills, visible when a Bot connection exists, with sections Skills Hub, MCP,
  Plugins, Config, Keys, Logs, Gateway. Existing webui-backed Skills/Memory screens stay.
- **Safety rules:**
  - Env keys are write-only from the phone. Never call `POST /api/env/reveal`; show
    only the server's redacted preview.
  - Face ID / passcode (`LAContext.deviceOwnerAuthentication`) before: writing or
    deleting an env key, saving raw `config.yaml`, gateway stop/restart, and deleting
    or uninstalling any MCP server, plugin or skill.
  - Installs (skills hub, plugins, MCP catalog) always show source, preview and the
    security scan result before a confirm button.
  - Never show success before the server confirms; destructive copy states the real
    consequence.
- **Contract pin:** dashboard routes are verified against hermes-agent
  `HERMES_AGENT_TESTED_SHA` (0.21.x). Verify shapes by reading the router source in
  `~/.hermes/hermes-agent/hermes_cli/web_routers/`. Record verified route/shape per PR.

## Build order (one card each, in order)

1. Dashboard destination shell + dashboard HTTP client (sign-in reuse, GET/PUT/POST/
   PATCH/DELETE helpers, tolerant decoding) + Skills Hub (search, preview, scan,
   install, update, uninstall, installed list).
2. MCP: list, enable/disable, test, delete, per-server tools; catalog browse + install.
3. MCP: add server manually (url or stdio, headers/env as secrets), OAuth start →
   `ASWebAuthenticationSession` → poll flow status.
4. Plugins: list, enable/disable, install from hub/catalog, update, remove.
5. Config (structured read + raw editor behind Face ID), Keys (write-only), Logs
   (tail), Gateway status/start/stop/restart.

## Live dashboard (no credentials for lanes)

- URL: `https://macstudio-von-daniel.tailbcd47c.ts.net:9443` (Tailscale Serve, tailnet
  only). The dashboard itself listens on `127.0.0.1:9119`; the old
  `http://100.67.209.26:9119` address is closed.
- Lanes have **no dashboard credential**. Verify routes and shapes from the router
  source in `~/.hermes/hermes-agent/hermes_cli/web_routers/` and build test fixtures
  from those shapes. Unauthenticated `GET /api/status` is the only live call allowed.
- Never add, log or commit a password, cookie or token.

## Definition of done for a card

- Focused XCTest for new networking/decoding/view-model behavior, using
  `URLProtocol` mocks and tolerant fixtures captured from the real router shapes.
- `scripts/test-sim <lane-udid> --only …` green for affected classes; full suite when
  touching the Xcode project or `Config/`.
- `python3 ci/check_string_catalog.py` clean after a build (new strings in
  `Localizable.xcstrings`).
- Signed Debug build launches on the lane simulator (XcodeBuildMCP `build_run_sim`),
  and one screenshot of the new screen is saved outside the worktree.
- Commits are conventional, on the card branch, working tree clean.
