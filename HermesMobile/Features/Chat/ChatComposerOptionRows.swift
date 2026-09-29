import SwiftUI
import UIKit

/// One setting under the attachment choices in the Sessions composer's `+`
/// panel, such as "Workspace: Home ›". These moved out of the bottom row so
/// the row fits the phone without scrolling.
struct ComposerOptionRow: Identifiable {
    enum ID: String {
        case workspace
        case profile
        case branch
    }

    enum Action {
        /// The panel dismisses first, then the composer presents a sheet.
        case present(() -> Void)
        /// A menu that opens in place; its choice dismisses the panel.
        case menu(() -> UIMenu)
        /// Nothing to choose: a plain label without chevron or button trait.
        case none
    }

    let id: ID
    /// The visible and spoken text, "Workspace: Home".
    let title: String
    /// The part of `title` that may truncate, "Home".
    let value: String
    let systemImage: String
    let isEnabled: Bool
    let action: Action

    /// `title` split around `value`, so a long workspace or branch name
    /// truncates and the label in front of it never does. A translation that
    /// drops the value truncates as a whole.
    var titleParts: (lead: String, value: String, trail: String) {
        guard !value.isEmpty, let range = title.range(of: value, options: .backwards) else {
            return ("", title, "")
        }
        return (String(title[..<range.lowerBound]), value, String(title[range.upperBound...]))
    }
}

extension ComposerOptionRow {
    /// The Sessions composer's rows, in order: Workspace, Profile, then Branch
    /// when the workspace is a git repository (`branchName` is non-nil).
    /// `profileMenu` is nil on a single-profile server, which rejects switches
    /// (#24), so that row is static.
    static func sessionRows(
        workspaceTitle: String,
        profileTitle: String,
        profileMenu: (() -> UIMenu)?,
        branchName: String?,
        isConfigurationDisabled: Bool,
        isBranchDisabled: Bool,
        onWorkspace: @escaping () -> Void,
        onBranch: @escaping () -> Void
    ) -> [ComposerOptionRow] {
        var rows = [
            ComposerOptionRow(
                id: .workspace,
                title: String(localized: "Workspace: \(workspaceTitle)"),
                value: workspaceTitle,
                systemImage: "folder",
                isEnabled: !isConfigurationDisabled,
                action: .present(onWorkspace)
            ),
            ComposerOptionRow(
                id: .profile,
                title: String(localized: "Profile: \(profileTitle)"),
                value: profileTitle,
                systemImage: "person.crop.circle",
                isEnabled: !isConfigurationDisabled,
                action: profileMenu.map { .menu($0) } ?? .none
            )
        ]
        if let branchName {
            rows.append(ComposerOptionRow(
                id: .branch,
                title: String(localized: "Branch: \(branchName)"),
                value: branchName,
                systemImage: "arrow.triangle.branch",
                isEnabled: !isBranchDisabled,
                action: .present(onBranch)
            ))
        }
        return rows
    }
}

/// What the Sessions composer presents once the `+` panel has dismissed.
enum ComposerPickerFollowUp {
    case files
    case workspace
    case branch
}

/// A `ComposerOptionRow` drawn like `HermexAttachmentMenuRow`: circled icon,
/// one line of text, 66 pt tall. `onPresent` runs a `.present` action and
/// dismisses the panel.
struct ComposerOptionRowView: View {
    let row: ComposerOptionRow
    let onPresent: (() -> Void) -> Void

    var body: some View {
        switch row.action {
        case let .present(action):
            Button {
                onPresent(action)
            } label: {
                content(showsChevron: true)
            }
            .buttonStyle(.plain)
            .disabled(!row.isEnabled)
            .accessibilityLabel(row.title)
        case let .menu(makeMenu):
            // The panel only exists while open, so building the short menu
            // up front costs nothing and it opens without a loading pass.
            ChatUIKitMenuButton(loadsMenuEagerly: true) {
                content(showsChevron: true)
            } menu: {
                makeMenu()
            }
            .disabled(!row.isEnabled)
            .accessibilityLabel(row.title)
        case .none:
            content(showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.title)
        }
    }

    private func content(showsChevron: Bool) -> some View {
        let parts = row.titleParts
        return HStack(spacing: 14) {
            Image(systemName: row.systemImage)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 42, height: 42)
                .background(.primary.opacity(0.08), in: Circle())
            HStack(spacing: 0) {
                Text(verbatim: parts.lead)
                    .layoutPriority(1)
                Text(verbatim: parts.value)
                    .truncationMode(.middle)
                Text(verbatim: parts.trail)
                    .layoutPriority(1)
            }
            .font(.title3.weight(.regular))
            .lineLimit(1)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: HermexAttachmentPickerLayoutMetrics.menuRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The branch picker the `+` panel's Branch row opens, as a sheet.
struct ComposerBranchSheet: View {
    let gitViewModel: GitWorkspaceAvailabilityViewModel
    let onSelect: (GitCheckoutTarget) -> Void
    let onCreate: (GitCheckoutTarget) -> Void
    let onRefresh: () -> Void

    var body: some View {
        GitBranchPickerSheet(
            branches: gitViewModel.branches,
            currentBranch: gitViewModel.currentBranchName,
            isLoading: gitViewModel.isLoadingBranches,
            isSwitching: gitViewModel.isSwitchingBranch,
            onSelect: onSelect,
            onCreate: onCreate,
            onRefresh: onRefresh
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
