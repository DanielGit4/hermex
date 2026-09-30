import Observation
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// The Sessions composer's bottom row, hosted in phone-sized windows: every
/// control stays on screen without scrolling, and the model chip absorbs the
/// squeeze by truncating.
@MainActor final class ChatComposerBottomRowLayoutTests: XCTestCase {
    private static let existingChatIDs = [
        "composer.plus", "composer.modelEffort", "composer.voice", "composer.contextRing", "composer.send"
    ]

    private var restoreAutomation: (() -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        restoreAutomation = try XCTUnwrap(InProcessAccessibility.enableAutomation(),
                                          "libAccessibility is unavailable")
    }

    override func tearDown() async throws {
        restoreAutomation?()
        restoreAutomation = nil
        try await super.tearDown()
    }

    func testExistingChatRowFitsIPhone17AtDefaultSize() async throws {
        let metrics = try await assertRowFits(width: 402, height: 874, dynamicTypeSize: .large)
        XCTAssertGreaterThanOrEqual(metrics.chipWidth, metrics.chipIdealWidth - 0.5,
                                    "\"Opus 5.5 · Max\" must show in full on a 402 pt phone")
    }

    func testExistingChatRowFitsIPhone17ProMaxAtDefaultSize() async throws {
        let metrics = try await assertRowFits(width: 440, height: 956, dynamicTypeSize: .large)
        XCTAssertGreaterThanOrEqual(metrics.chipWidth, metrics.chipIdealWidth - 0.5)
    }

    func testChipTruncatesInsteadOfScrollingAtAccessibilitySize() async throws {
        let metrics = try await assertRowFits(width: 402, height: 874, dynamicTypeSize: .accessibility3)
        XCTAssertLessThan(metrics.chipWidth, metrics.chipIdealWidth - 1, "The chip truncates rather than pushing controls away")
    }

    func testNewChatRowShowsNoContextRingUntilThereIsData() async throws {
        let focus = ComposerRowFocus()
        let window = try show(ComposerRowFixture(focus: focus, snapshot: nil, git: Self.noRepository()), width: 402, height: 874)
        defer { close(window) }
        await renderFrames()
        focus.isFocused = true
        let ids = Self.existingChatIDs.filter { $0 != "composer.contextRing" }
        let frames = try await rowFrames(in: window, ids: ids)

        assertInside(frames, width: 402)
        XCTAssertFalse(accessibilityElements(in: window).contains { $0.identifier == "composer.contextRing" })
    }

    // MARK: + panel

    func testPlusPanelListsWorkspaceProfileAndBranchUnderTheAttachments() async throws {
        let restoreGit = overrideDefault(SectionVisibilitySettings.chatGitKey, true)
        defer { restoreGit() }
        let git = try await Self.repository(branch: "main")
        let focus = ComposerRowFocus()
        let window = try show(ComposerRowFixture(focus: focus, snapshot: nil, git: git,
                                                 profiles: Self.profiles, isSingleProfileMode: false),
                              width: 402, height: 874)
        defer { close(window) }
        let overlay = try await openPlusPanel(in: window, focus: focus)

        let elements = accessibilityElements(in: overlay)
        let expected = ["Files", "Camera", "Photos", "Workspace: hermes-mobile", "Profile: Default", "Branch: main"]
        let tops = try expected.map { title in
            try XCTUnwrap(elements.first { $0.label == title }, "\(title) missing from \(elements.compactMap(\.label))").frame.minY
        }
        XCTAssertEqual(tops, tops.sorted(), "Rows appear top to bottom in this order: \(zip(expected, tops).map { "\($0) \($1)" })")
    }

    func testProfileRowSelectsTheProfileAndClosesThePanel() async throws {
        var selected: [String] = []
        let chosen = expectation(description: "profile chosen")
        let focus = ComposerRowFocus()
        let window = try show(ComposerRowFixture(focus: focus, snapshot: nil, git: Self.noRepository(),
                                                 profiles: Self.profiles, isSingleProfileMode: false,
                                                 onSelectProfile: { selected.append($0.name ?? ""); chosen.fulfill() }),
                              width: 402, height: 874)
        defer { close(window) }
        let overlay = try await openPlusPanel(in: window, focus: focus)

        let menuButton = try XCTUnwrap(descendants(overlay).compactMap { $0 as? UIButton }.first { $0.showsMenuAsPrimaryAction })
        let section = try XCTUnwrap(menuButton.menu?.children.first as? UIMenu)
        let work = try XCTUnwrap(section.children.compactMap { $0 as? UIAction }.first { $0.title == "work" })
        menuButton.sendAction(work)
        await fulfillment(of: [chosen], timeout: 3)

        XCTAssertEqual(selected, ["work"])
        let closed = await waitUntil { !self.hasOverlay(in: window) }
        XCTAssertTrue(closed, "Choosing a profile closes the + panel")
    }

    func testWorkspaceRowPresentsTheWorkspaceSheetAfterThePanelCloses() async throws {
        let focus = ComposerRowFocus()
        let window = try show(ComposerRowFixture(focus: focus, snapshot: nil, git: Self.noRepository()), width: 402, height: 874)
        defer { close(window) }
        let overlay = try await openPlusPanel(in: window, focus: focus)
        XCTAssertNil(window.rootViewController?.presentedViewController)

        let workspace = try XCTUnwrap(accessibilityElements(in: overlay).first { $0.label == "Workspace: hermes-mobile" })
        XCTAssertTrue(workspace.object.accessibilityActivate())

        let presented = await waitUntil { window.rootViewController?.presentedViewController != nil }
        XCTAssertTrue(presented, "The workspace sheet follows the panel")
        XCTAssertFalse(hasOverlay(in: window), "The panel is gone before the sheet shows")
    }

    func testBranchRowPresentsTheBranchSheet() async throws {
        let restoreGit = overrideDefault(SectionVisibilitySettings.chatGitKey, true)
        defer { restoreGit() }
        let git = try await Self.repository(branch: "feature/row")
        let focus = ComposerRowFocus()
        let window = try show(ComposerRowFixture(focus: focus, snapshot: nil, git: git), width: 402, height: 874)
        defer { close(window) }
        let overlay = try await openPlusPanel(in: window, focus: focus)

        let branch = try XCTUnwrap(accessibilityElements(in: overlay).first { $0.label == "Branch: feature/row" })
        XCTAssertTrue(branch.object.accessibilityActivate())

        let presented = await waitUntil { window.rootViewController?.presentedViewController != nil }
        XCTAssertTrue(presented, "The branch sheet follows the panel")
    }

    // MARK: Row assertions

    private struct RowMetrics {
        let chipWidth: CGFloat
        let chipIdealWidth: CGFloat
    }

    private func assertRowFits(
        width: CGFloat,
        height: CGFloat,
        dynamicTypeSize: DynamicTypeSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> RowMetrics {
        let focus = ComposerRowFocus()
        let window = try show(
            ComposerRowFixture(focus: focus, snapshot: Self.snapshot, git: Self.noRepository())
                .environment(\.dynamicTypeSize, dynamicTypeSize),
            width: width,
            height: height
        )
        defer { close(window) }
        await renderFrames()
        focus.isFocused = true
        let frames = try await rowFrames(in: window, ids: Self.existingChatIDs)

        assertInside(frames, width: width, file: file, line: line)
        for id in Self.existingChatIDs where id != "composer.modelEffort" {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames[id]).width, 44 - 0.5, "\(id) keeps its 44 pt target", file: file, line: line)
        }

        let chip = try XCTUnwrap(accessibilityElements(in: window).first { $0.identifier == "composer.modelEffort" })
        XCTAssertEqual(chip.label, "Model: Claude Opus 5.5, Max", file: file, line: line)

        // The chip is the row's only UIKit menu button; nothing between it
        // and the window may scroll.
        let menuButtons = descendants(window).compactMap { $0 as? UIButton }.filter(\.showsMenuAsPrimaryAction)
        XCTAssertEqual(menuButtons.count, 1, file: file, line: line)
        let chipButton = try XCTUnwrap(menuButtons.first)
        XCTAssertFalse(ancestors(of: chipButton).contains { $0 is UIScrollView },
                       "The bottom row must not scroll", file: file, line: line)

        let chipWidth = try XCTUnwrap(frames["composer.modelEffort"]).width
        return RowMetrics(chipWidth: chipWidth, chipIdealWidth: idealChipWidth(dynamicTypeSize: dynamicTypeSize))
    }

    private func assertInside(
        _ frames: [String: CGRect],
        width: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (id, frame) in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(id) starts off screen: \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width, "\(id) ends off screen: \(frame)", file: file, line: line)
        }
        let sorted = frames.sorted { $0.value.minX < $1.value.minX }
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(left.value.maxX, right.value.minX + 0.5,
                                     "\(left.key) overlaps \(right.key)", file: file, line: line)
        }
    }

    /// The chip's width with nothing constraining it, in the same fonts.
    private func idealChipWidth(dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let chip = ComposerModelEffortMenu(
            selection: ComposerModelEffortSelection(
                model: Self.opus, effort: "max", supportedEfforts: Self.efforts, supportsEffort: true
            ),
            modelGroups: [], favoriteModelKeys: [], recentModelKeys: [], isDisabled: false,
            color: Color(.secondaryLabel), controlFont: AppFont.subheadline(), chevronFont: AppFont.caption2(),
            onSelectModel: { _ in }, onSelectEffort: { _ in }, onShowAllModels: {}
        )
        let host = UIHostingController(rootView: chip.environment(\.dynamicTypeSize, dynamicTypeSize))
        return host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
    }

    /// Frames of the given row identifiers, once all of them are laid out.
    /// Renders first: reading the accessibility tree forces a layout that
    /// can find the row before its UIKit-backed pieces are mounted.
    private func rowFrames(in window: UIWindow, ids: [String]) async throws -> [String: CGRect] {
        await renderFrames()
        var frames: [String: CGRect] = [:]
        _ = await waitUntil {
            frames = [:]
            for element in self.accessibilityElements(in: window) {
                if let id = element.identifier, ids.contains(id) { frames[id] = element.frame }
            }
            return frames.count == ids.count
        }
        let all = accessibilityElements(in: window)
        XCTAssertEqual(Set(frames.keys), Set(ids),
                       "Row elements found: \(frames.keys.sorted()); identifiers: \(all.compactMap(\.identifier)); labels: \(all.compactMap(\.label))")
        return frames
    }

    // MARK: + panel helpers

    private func openPlusPanel(in window: UIWindow, focus: ComposerRowFocus) async throws -> UIView {
        await renderFrames()
        focus.isFocused = true
        _ = try await rowFrames(in: window, ids: ["composer.plus"])
        let plus = try XCTUnwrap(accessibilityElements(in: window).first { $0.identifier == "composer.plus" })
        XCTAssertTrue(plus.object.accessibilityActivate())
        var overlay: UIView?
        _ = await waitUntil {
            overlay = self.overlayHost(in: window)
            return overlay.map { self.accessibilityElements(in: $0).contains { $0.label == "Photos" } } ?? false
        }
        return try XCTUnwrap(overlay, "The + panel did not open")
    }

    private func overlayHost(in window: UIWindow) -> UIView? {
        descendants(window).first {
            $0.accessibilityIdentifier == HermexAttachmentPickerPresentation.overlayHostAccessibilityIdentifier
        }
    }

    private func hasOverlay(in window: UIWindow) -> Bool {
        overlayHost(in: window) != nil
    }

    // MARK: Fixtures

    private static let opus = ModelCatalogOption(id: "claude-opus-5-5", displayName: "Claude Opus 5 5", providerID: "anthropic")
    private static let efforts = ["low", "medium", "high", "max"]
    private static let snapshot = ContextWindowSnapshot(
        contextLength: 200_000, thresholdTokens: 160_000, lastPromptTokens: 124_000,
        inputTokens: 124_000, outputTokens: 3_000, estimatedCost: 0.42
    )
    private static let profiles = ["default", "work"].map { name in
        ProfileSummary(name: name, path: nil, isDefault: nil, isActive: nil, gatewayRunning: nil,
                       model: nil, provider: nil, hasEnv: nil, skillCount: nil)
    }

    private static func noRepository() -> GitWorkspaceAvailabilityViewModel {
        GitWorkspaceAvailabilityViewModel(session: SessionSummary(), server: URL(string: "https://webui.example")!)
    }

    /// A git view model that has loaded a repository on `branch` from a mock server.
    private static func repository(branch: String) async throws -> GitWorkspaceAvailabilityViewModel {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"\#(branch)"}}"#, for: request)
            case "/api/git/status":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"\#(branch)","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse(
                    #"{"branches":{"is_git":true,"current":"\#(branch)","local":[{"name":"\#(branch)"}],"remote":[]}}"#,
                    for: request
                )
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let server = URL(string: "https://example.test")!
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id": "s1", "title": "T", "workspace": "/Users/example/hermes-mobile"}"#.utf8)
        )
        let git = GitWorkspaceAvailabilityViewModel(session: session, server: server, apiClient: client)
        await git.load()
        XCTAssertTrue(git.hasRepository)
        return git
    }

    // MARK: Hosting

    private func show<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light
        // Layout assertions must not capture an intermediate composer spring frame.
        window.rootViewController = UIHostingController(rootView: view.transaction { $0.disablesAnimations = true })
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func ancestors(of view: UIView) -> [UIView] {
        var result: [UIView] = []
        var current = view.superview
        while let next = current {
            result.append(next)
            current = next.superview
        }
        return result
    }

    private static let identifierSelector = NSSelectorFromString("accessibilityIdentifier")

    private struct AccessibilityElement {
        let object: NSObject
        let identifier: String?
        let label: String?
        let frame: CGRect
    }

    /// Every accessibility element under `root`, views and SwiftUI's
    /// non-view nodes alike, with identifier, label and screen frame (the
    /// test windows sit at the origin, so screen and window agree).
    private func accessibilityElements(in root: UIView) -> [AccessibilityElement] {
        var result: [AccessibilityElement] = []
        var queue: [NSObject] = [root]
        var seen: Set<ObjectIdentifier> = []
        while let object = queue.popLast() {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            // SwiftUI's nodes answer the identifier getter without declaring
            // the protocol, so ask by selector.
            let identifier = object.responds(to: Self.identifierSelector)
                ? object.value(forKey: "accessibilityIdentifier") as? String
                : nil
            result.append(AccessibilityElement(
                object: object,
                identifier: identifier,
                label: object.accessibilityLabel,
                frame: object.accessibilityFrame
            ))
            queue += (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                queue += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = object as? UIView { queue += view.subviews }
        }
        return result
    }

    private func renderFrames(_ target: Int = 3) async {
        let rendered = expectation(description: "Layout committed")
        let driver = BotRenderFrameDriver(target: target) { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
    }

    /// Renders frames until `condition` holds, for state that settles over a
    /// few frames (row insertion, the panel's fade-out, a sheet presenting).
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            await renderFrames(4)
        }
        return condition()
    }

    private func overrideDefault(_ key: String, _ value: Bool) -> () -> Void {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.set(value, forKey: key)
        return {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}

final class ComposerOptionRowTests: XCTestCase {
    func testSessionRowsListWorkspaceProfileAndBranchInOrder() {
        let rows = sessionRows(branchName: "main")

        XCTAssertEqual(rows.map(\.id), [.workspace, .profile, .branch])
        XCTAssertEqual(rows.map(\.title), ["Workspace: Home", "Profile: Default", "Branch: main"])
        XCTAssertEqual(rows.map(\.systemImage), ["folder", "person.crop.circle", "arrow.triangle.branch"])
        XCTAssertTrue(rows.allSatisfy(\.isEnabled))
    }

    func testOnlyTheValueTruncates() {
        let workspace = sessionRows(branchName: nil)[0]
        XCTAssertEqual(workspace.titleParts.lead, "Workspace: ")
        XCTAssertEqual(workspace.titleParts.value, "Home")
        XCTAssertEqual(workspace.titleParts.trail, "")

        let untranslatable = ComposerOptionRow(
            id: .branch, title: "Zweig", value: "main", systemImage: "arrow.triangle.branch",
            isEnabled: true, action: .none
        )
        XCTAssertEqual(untranslatable.titleParts.lead, "")
        XCTAssertEqual(untranslatable.titleParts.value, "Zweig", "A title without its value truncates whole")
    }

    func testBranchRowNeedsARepository() {
        XCTAssertEqual(sessionRows(branchName: nil).map(\.id), [.workspace, .profile])
    }

    func testSingleProfileServersGetAStaticProfileRow() {
        let rows = sessionRows(branchName: nil, hasProfileMenu: false)
        guard case .none = rows[1].action else {
            return XCTFail("A single-profile server rejects switches, so the row is a label")
        }
    }

    func testConfigurationAndBranchLocksDisableTheirRows() {
        let locked = sessionRows(branchName: "main", isConfigurationDisabled: true)
        XCTAssertEqual(locked.map(\.isEnabled), [false, false, true])

        let switching = sessionRows(branchName: "main", isBranchDisabled: true)
        XCTAssertEqual(switching.map(\.isEnabled), [true, true, false])
    }

    func testRowsRouteToTheirActions() {
        var presented: [String] = []
        let rows = ComposerOptionRow.sessionRows(
            workspaceTitle: "Home", profileTitle: "Default",
            profileMenu: { UIMenu(title: "Profiles", children: []) },
            branchName: "main", isConfigurationDisabled: false, isBranchDisabled: false,
            onWorkspace: { presented.append("workspace") }, onBranch: { presented.append("branch") }
        )

        for row in rows {
            switch row.action {
            case let .present(action): action()
            case let .menu(makeMenu): XCTAssertEqual(makeMenu().title, "Profiles")
            case .none: XCTFail("\(row.id) should be interactive")
            }
        }
        XCTAssertEqual(presented, ["workspace", "branch"])
    }

    func testMenuSpansThePhoneOnlyWithComposerOptions() {
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: 402), 280)
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: 402, hasComposerOptions: true), 378)
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: 1024, hasComposerOptions: true), 400)
    }

    func testMenuHeightGrowsByOneRowPerOption() {
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuHeight(optionRowCount: 0), 222, "Bot's panel keeps its size")
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuHeight(optionRowCount: 2), 222 + 2 * 66 + 9)
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuHeight(optionRowCount: 3), 222 + 3 * 66 + 9)
    }

    private func sessionRows(
        branchName: String?,
        hasProfileMenu: Bool = true,
        isConfigurationDisabled: Bool = false,
        isBranchDisabled: Bool = false
    ) -> [ComposerOptionRow] {
        ComposerOptionRow.sessionRows(
            workspaceTitle: "Home",
            profileTitle: "Default",
            profileMenu: hasProfileMenu ? { UIMenu(children: []) } : nil,
            branchName: branchName,
            isConfigurationDisabled: isConfigurationDisabled,
            isBranchDisabled: isBranchDisabled,
            onWorkspace: {},
            onBranch: {}
        )
    }
}

/// SwiftUI publishes its accessibility tree in-process only while an assistive
/// technology or UI automation is on. These hosted tests turn automation on,
/// as XCUITest does, to read control frames by identifier, and restore the
/// previous state afterwards.
private enum InProcessAccessibility {
    private typealias IsEnabled = @convention(c) () -> Int32
    private typealias SetEnabled = @convention(c) (Int32) -> Void

    static func enableAutomation() -> (() -> Void)? {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let isEnabledSymbol = dlsym(library, "_AXSAutomationEnabled"),
              let setEnabledSymbol = dlsym(library, "_AXSSetAutomationEnabled")
        else { return nil }
        let isEnabled = unsafeBitCast(isEnabledSymbol, to: IsEnabled.self)
        let setEnabled = unsafeBitCast(setEnabledSymbol, to: SetEnabled.self)
        let previous = isEnabled()
        setEnabled(1)
        return { setEnabled(previous) }
    }
}

/// Holds the composer's screen-owned focus binding for these hosted tests.
@MainActor @Observable private final class ComposerRowFocus {
    var isFocused = false
}

/// `MessageComposerView` wired like `ChatView`, with an Opus 5.5 model at Max
/// effort and a workspace named hermes-mobile.
private struct ComposerRowFixture: View {
    @Bindable var focus: ComposerRowFocus
    let snapshot: ContextWindowSnapshot?
    let git: GitWorkspaceAvailabilityViewModel
    var profiles: [ProfileSummary] = []
    var isSingleProfileMode = true
    var onSelectProfile: (ProfileSummary) -> Void = { _ in }
    @State private var draft = ChatComposerDraft(text: "")
    @State private var quotes: [ComposerQuote] = []
    @State private var paths = ComposerFilePathSearch()

    private static let groups = [
        ModelCatalogGroup(
            id: "anthropic", name: "Anthropic", providerID: "anthropic",
            models: [ModelCatalogOption(id: "claude-opus-5-5", displayName: "Claude Opus 5 5", providerID: "anthropic")]
        )
    ]

    var body: some View {
        VStack {
            Spacer()
            MessageComposerView(
                draft: draft, quotes: $quotes, isFocused: $focus.isFocused,
                isSending: false, isCompressingSession: false, isWaitingForStream: false,
                isCancellingStream: false, readOnlyMessage: nil, errorMessage: nil,
                configurationErrorMessage: nil, contextWindowSnapshot: snapshot, gitViewModel: git,
                modelGroups: Self.groups, selectedModelID: "claude-opus-5-5", selectedModelProviderID: "anthropic",
                selectedModelTitle: "Claude Opus 5 5",
                workspaceRoots: [], selectedWorkspacePath: "/Users/example/hermes-mobile", workspaceSuggestions: [],
                workspaceManagementServer: nil,
                personalitySuggestions: [], skillSuggestions: [], hasLoadedSkillSuggestions: true,
                agentCommands: [], profileOptions: profiles, isSingleProfileMode: isSingleProfileMode,
                selectedProfileName: nil, selectedProfileTitle: "Default", selectedReasoningEffort: "max",
                supportedReasoningEfforts: ["low", "medium", "high", "max"], supportsReasoningEffort: true,
                showsReasoningControl: true,
                isUpdatingConfiguration: false, pendingAttachments: [], isUploadingAttachment: false,
                attachmentUploadCount: 0, attachmentUploadGeneration: 0, isSendingVoiceNote: false,
                autoStartsVoiceInput: false, apiClient: nil, sessionID: nil, chipFilePaths: [],
                filePathSearch: paths, uploadAttachmentErrorMessage: nil,
                onSend: {}, onSendVoiceNote: { _, _ in }, onCancel: {}, onSelectModel: { _ in },
                onModelPickerOpen: {}, onSelectReasoningEffort: { _ in }, onLoadWorkspaceSuggestions: { _ in },
                onWorkspaceRegistryChanged: {}, onLoadPersonalitySuggestions: {}, onLoadSkillSuggestions: {},
                onSelectWorkspace: { _ in }, onSelectProfile: onSelectProfile, onHeightChange: { _ in },
                onPhotoMediaSelected: { _ in }, onFileURLsSelected: { _ in }, onPasteFileProviders: { _ in },
                onPasteFileURLs: { _ in }, onPasteImageProviders: { _ in }, onPasteImages: { _ in },
                onRemoveAttachment: { _ in }, onPreviewAttachment: { _ in }, onDismissUploadAttachmentError: {},
                onSelectFileReference: { _ in }, onFileReferenceCandidatesChange: { _ in },
                onDraftEdit: { _ in },
                onOpenFileReference: { _ in }, onSelectGitBranch: { _ in },
                onCreateGitBranch: { _ in }, onRefreshGitBranches: {}
            )
        }
    }
}

/// The chat's offline banner, hosted in a phone-sized window: the reason reads
/// with the title, Try Again runs one retry at a time, and at accessibility
/// sizes the button moves below the text.
@MainActor final class ChatOfflineCacheBannerTests: XCTestCase {
    private static let reason = APIError.networkMessage(for: .cannotConnectToHost, host: "macstudio.tail1234.ts.net")

    private var restoreAutomation: (() -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        restoreAutomation = try XCTUnwrap(InProcessAccessibility.enableAutomation(),
                                          "libAccessibility is unavailable")
    }

    override func tearDown() async throws {
        restoreAutomation?()
        restoreAutomation = nil
        try await super.tearDown()
    }

    func testReasonReadsWithTheTitleAndTryAgainIsItsOwnElement() async throws {
        let window = try show(ChatOfflineCacheBanner(reason: Self.reason) {})
        defer { close(window) }

        let text = try await textElement(in: window)
        XCTAssertTrue(text.label?.contains("Offline — viewing cached version") == true, text.label ?? "nil")
        XCTAssertTrue(text.label?.contains(Self.reason) == true, text.label ?? "nil")
        let button = try await retryButton(in: window)
        XCTAssertEqual(button.label, "Try Again")
    }

    func testTryAgainRunsOnceWhileARetryIsInFlight() async throws {
        let probe = RetryProbe()
        let window = try show(ChatOfflineCacheBanner(reason: Self.reason) { await probe.run() })
        defer {
            probe.finish()
            close(window)
        }

        let first = try await retryButton(in: window)
        XCTAssertTrue(first.object.accessibilityActivate())
        let started = await waitUntil { probe.calls == 1 }
        XCTAssertTrue(started, "The first tap starts a retry")

        let second = try await retryButton(in: window)
        _ = second.object.accessibilityActivate()
        await renderFrames()
        XCTAssertEqual(probe.calls, 1, "A tap while the retry runs does not start another")

        probe.finish()
        let enabled = await waitUntil {
            self.accessibilityElements(in: window)
                .first { $0.identifier == "chat.offlineBanner.retry" }
                .map { !$0.object.accessibilityTraits.contains(.notEnabled) } ?? false
        }
        XCTAssertTrue(enabled, "Try Again is enabled again once the retry finishes")
        let third = try await retryButton(in: window)
        XCTAssertTrue(third.object.accessibilityActivate())
        let restarted = await waitUntil { probe.calls == 2 }
        XCTAssertTrue(restarted, "A tap after the retry finished starts another")
    }

    func testAccessibilitySizeMovesTryAgainBelowTheText() async throws {
        let window = try show(
            ChatOfflineCacheBanner(reason: Self.reason) {}.environment(\.dynamicTypeSize, .accessibility3)
        )
        defer { close(window) }

        let text = try await textElement(in: window)
        let button = try await retryButton(in: window)
        XCTAssertGreaterThanOrEqual(button.frame.minX, 0, "\(button.frame)")
        XCTAssertLessThanOrEqual(button.frame.maxX, 402, "\(button.frame)")
        XCTAssertFalse(button.frame.intersects(text.frame), "text \(text.frame), button \(button.frame)")
        XCTAssertGreaterThanOrEqual(button.frame.minY, text.frame.maxY - 0.5, "Try Again sits below the text")
    }

    // MARK: Elements

    private func textElement(in window: UIWindow) async throws -> AccessibilityElement {
        try await element(in: window) { $0.label?.contains("Offline — viewing cached version") == true }
    }

    private func retryButton(in window: UIWindow) async throws -> AccessibilityElement {
        try await element(in: window) { $0.identifier == "chat.offlineBanner.retry" }
    }

    /// The first element matching `match`, once the hosted view has published it.
    private func element(
        in window: UIWindow,
        where match: (AccessibilityElement) -> Bool
    ) async throws -> AccessibilityElement {
        var found: AccessibilityElement?
        _ = await waitUntil {
            found = self.accessibilityElements(in: window).first(where: match)
            return found != nil
        }
        return try XCTUnwrap(found, "Elements: \(accessibilityElements(in: window).compactMap(\.label))")
    }

    // MARK: Hosting

    private func show<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transaction { $0.disablesAnimations = true }
        )
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static let identifierSelector = NSSelectorFromString("accessibilityIdentifier")

    private struct AccessibilityElement {
        let object: NSObject
        let identifier: String?
        let label: String?
        let frame: CGRect
    }

    /// Every accessibility element under `root`, views and SwiftUI's non-view
    /// nodes alike (the test window sits at the origin, so frames are window
    /// coordinates).
    private func accessibilityElements(in root: UIView) -> [AccessibilityElement] {
        var result: [AccessibilityElement] = []
        var queue: [NSObject] = [root]
        var seen: Set<ObjectIdentifier> = []
        while let object = queue.popLast() {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let identifier = object.responds(to: Self.identifierSelector)
                ? object.value(forKey: "accessibilityIdentifier") as? String
                : nil
            result.append(AccessibilityElement(
                object: object,
                identifier: identifier,
                label: object.accessibilityLabel,
                frame: object.accessibilityFrame
            ))
            queue += (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                queue += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = object as? UIView { queue += view.subviews }
        }
        return result
    }

    private func renderFrames(_ target: Int = 3) async {
        let rendered = expectation(description: "Layout committed")
        let driver = BotRenderFrameDriver(target: target) { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
    }

    /// Renders frames until `condition` holds, for state that settles over a few frames.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            await renderFrames(4)
        }
        return condition()
    }
}

/// Counts Try Again runs and holds each one until the test finishes it.
@MainActor private final class RetryProbe {
    private(set) var calls = 0
    private var pending: CheckedContinuation<Void, Never>?

    func run() async {
        calls += 1
        await withCheckedContinuation { pending = $0 }
    }

    func finish() {
        pending?.resume()
        pending = nil
    }
}
