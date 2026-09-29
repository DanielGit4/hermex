import XCTest
@testable import HermesMobile

final class ChatToolbarHeaderTests: XCTestCase {
    func testSubtitleUsesWorkspaceBasenameBeforeProfile() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: "/Users/example/hermes-mobile",
                profileName: nil,
                profileTitle: "Default"
            ),
            "hermes-mobile"
        )
    }

    func testSubtitleFallsBackToStableProfileTitle() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: nil,
                profileName: "work",
                profileTitle: "Work"
            ),
            "Work"
        )
    }

    func testSubtitleOmitsGenericOrBlankContext() {
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileName: nil, profileTitle: "Profile"))
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: "   ", profileName: "  ", profileTitle: "   "))
    }

    /// The profile left the composer row, so a non-default one shows here.
    func testSubtitleAddsANonDefaultProfileAfterTheWorkspace() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: "/Users/example/hermes-mobile",
                profileName: " work ",
                profileTitle: "Work"
            ),
            "hermes-mobile · Work"
        )
    }

    func testSubtitleKeepsTheDefaultProfileHidden() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: "/Users/example/hermes-mobile",
                profileName: "default",
                profileTitle: "Default"
            ),
            "hermes-mobile"
        )
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: "/Users/example/hermes-mobile",
                profileName: "   ",
                profileTitle: "Profile"
            ),
            "hermes-mobile"
        )
    }
}
