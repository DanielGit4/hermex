import SwiftUI

/// One hub skill before it is installed: where it comes from, the host's security scan of
/// it, and its SKILL.md. The Install button appears only below all three, once both the
/// preview and the scan have loaded and the scan's policy lets the host install it.
struct SkillsHubDetailView: View {
    let model: SkillsHubViewModel
    let skill: HubSkill

    @State private var isConfirmingUninstall = false

    var body: some View {
        content
            .navigationTitle(skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.review(skill.identifier) }
            .safeAreaInset(edge: .bottom) { SkillsHubOperationBanner(model: model) }
            .confirmationDialog(
                uninstallTitle,
                isPresented: $isConfirmingUninstall,
                titleVisibility: .visible
            ) {
                Button("Uninstall", role: .destructive) {
                    guard let name = installedName else { return }
                    Task { await model.uninstall(name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the skill from the Hermes host.")
            }
            .alert("Couldn’t Confirm It’s You", isPresented: authenticationProblemIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.authenticationProblem ?? "")
            }
    }

    private var review: SkillsHubViewModel.Review? { model.reviews[skill.identifier] }

    /// The name the host installed this identifier under, which uninstall takes.
    private var installedName: String? {
        model.hubLock[skill.identifier]?.name ?? (model.isInstalled(skill.identifier) ? skill.name : nil)
    }

    private var uninstallTitle: String {
        String(localized: "Uninstall “\(installedName ?? skill.name)”?")
    }

    private var authenticationProblemIsPresented: Binding<Bool> {
        Binding(get: { model.authenticationProblem != nil }, set: { if !$0 { model.authenticationProblem = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if let review, review.state == .loaded, let preview = review.preview, let scan = review.scan {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(preview.skill)
                    SkillsHubScanSection(scan: scan)
                    previewSection(preview)
                    actionSection(scan)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        } else if case .failed(let problem)? = review?.state {
            SkillsHubProblemView(title: String(localized: "Could Not Load Skill"), problem: problem) {
                Task { await model.review(skill.identifier, force: true) }
            }
        } else {
            ProgressView("Loading the preview and security scan…")
        }
    }

    private func header(_ skill: HubSkill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(skill.name)
                .font(.title2.weight(.bold))

            if let description = skill.description {
                Text(description)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                if let source = skill.source {
                    SkillsHubBadge(text: source, systemImage: "shippingbox")
                }
                if let trust = skill.trustLevel {
                    SkillsHubBadge(text: SkillsHubLabels.trust(trust), systemImage: "checkmark.seal")
                }
            }

            Text(verbatim: skill.identifier)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let repo = skill.repo {
                Label {
                    Text(verbatim: repo)
                } icon: {
                    Image(systemName: "link")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            if !skill.tags.isEmpty {
                Text(verbatim: skill.tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func previewSection(_ preview: HubSkillPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.headline)

            if let markdown = preview.skillMarkdown {
                MarkdownRenderer(content: markdown)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("This skill has no SKILL.md to preview.")
                    .foregroundStyle(.secondary)
            }

            if !preview.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files")
                        .font(.subheadline.weight(.semibold))
                    ForEach(preview.files, id: \.self) { file in
                        Text(verbatim: file)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionSection(_ scan: HubSkillScan) -> some View {
        if model.isInstalled(skill.identifier) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if installedName != nil {
                    Button("Uninstall", role: .destructive) { isConfirmingUninstall = true }
                        .buttonStyle(.bordered)
                        .disabled(model.isWorking)
                }
            }
        } else if scan.allowsInstall {
            Button {
                Task { await model.install(skill.identifier) }
            } label: {
                if model.isRunning(.install(identifier: skill.identifier, name: review?.preview?.skill.name ?? skill.name)) {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Install on Hermes Host")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canInstall(skill.identifier))
        } else {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The host’s install policy refuses this skill, so Hermex won’t install it.")
                    if let reason = scan.policyReason {
                        Text(verbatim: reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct SkillsHubScanSection: View {
    let scan: HubSkillScan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Security Scan")
                .font(.headline)

            if let verdict = scan.verdict {
                Label {
                    Text(SkillsHubLabels.verdict(verdict))
                        .font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: verdictSymbol)
                        .foregroundStyle(verdictColor)
                }
            }

            if let summary = scan.summary {
                Text(verbatim: summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if scan.severityCounts.total > 0 {
                HStack(spacing: 6) {
                    severityBadge("critical", scan.severityCounts.critical)
                    severityBadge("high", scan.severityCounts.high)
                    severityBadge("medium", scan.severityCounts.medium)
                    severityBadge("low", scan.severityCounts.low)
                }
            }

            ForEach(Array(scan.findings.enumerated()), id: \.offset) { _, finding in
                FindingRow(finding: finding)
            }

            if let passed = scan.advisoryPassed {
                Text(passed
                     ? String(localized: "Advisory scan passed.")
                     : String(localized: "Advisory scan findings: \(scan.advisoryFindingCount ?? 0)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func severityBadge(_ severity: String, _ count: Int) -> some View {
        if count > 0 {
            SkillsHubBadge(text: "\(SkillsHubLabels.severity(severity)) \(count)")
        }
    }

    private var verdictSymbol: String {
        switch scan.verdict {
        case "safe": return "checkmark.shield.fill"
        case "caution": return "exclamationmark.shield.fill"
        case "dangerous": return "xmark.shield.fill"
        default: return "shield"
        }
    }

    private var verdictColor: Color {
        switch scan.verdict {
        case "safe": return .green
        case "caution": return .orange
        case "dangerous": return .red
        default: return .secondary
        }
    }
}

private struct FindingRow: View {
    let finding: HubSkillScan.Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let severity = finding.severity {
                    Text(SkillsHubLabels.severity(severity))
                        .font(.caption.weight(.semibold))
                }
                if let category = finding.category {
                    Text(verbatim: category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let description = finding.description {
                Text(verbatim: description)
                    .font(.caption)
            }
            if let file = finding.file {
                Text(verbatim: finding.line.map { "\(file):\($0)" } ?? file)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
