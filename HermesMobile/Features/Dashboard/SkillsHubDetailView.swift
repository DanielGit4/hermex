import SwiftUI

/// One hub skill before it is installed: where it comes from, the host's security scan of
/// it, and its SKILL.md. Install stays disabled until preview and scan load and the host's
/// policy explicitly allows it; a refused policy is shown instead of an install action.
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
        if let review {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(review.preview?.skill ?? skill)
                    scanSection(review)
                    previewSection(review)
                    actionSection(review)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        } else {
            ProgressView()
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

    @ViewBuilder
    private func scanSection(_ review: SkillsHubViewModel.Review) -> some View {
        switch review.scanState {
        case .loaded:
            if let scan = review.scan { SkillsHubScanSection(scan: scan) }
        case .failed(let problem):
            SkillsHubProblemView(title: String(localized: "Could Not Load Skill"), problem: problem) {
                Task { await model.retryScan(skill.identifier) }
            }
        case .idle, .loading:
            VStack(alignment: .leading, spacing: 10) {
                Text("Security Scan")
                    .font(.headline)
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func previewSection(_ review: SkillsHubViewModel.Review) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.headline)

            if let preview = review.preview, review.previewState == .loaded {
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
            } else if case .failed(let problem) = review.previewState {
                SkillsHubProblemView(title: String(localized: "Could Not Load Skill"), problem: problem) {
                    Task { await model.retryPreview(skill.identifier) }
                }
            } else {
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            }
        }
    }

    @ViewBuilder
    private func actionSection(_ review: SkillsHubViewModel.Review) -> some View {
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
        } else if review.scanState == .loaded, let scan = review.scan, !scan.allowsInstall {
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
        } else {
            Button {
                Task { await model.install(skill.identifier) }
            } label: {
                if model.isRunning(.install(identifier: skill.identifier, name: review.preview?.skill.name ?? skill.name)) {
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
        }
    }
}

/// A locally installed skill's host-owned metadata and SKILL.md. Hub skills retain the
/// same Face ID-gated uninstall path as the list; bundled and agent-created skills are read-only.
struct InstalledSkillDetailView: View {
    let model: SkillsHubViewModel
    let skill: DashboardSkill
    let lock: HubLockEntry?

    @State private var isConfirmingUninstall = false

    private var installedContent: DashboardSkillContent? { model.installedSkillContents[skill.name] }
    private var contentState: SkillsHubViewModel.LoadState {
        model.installedSkillContentStates[skill.name] ?? .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                documentSection
                if skill.isFromHub {
                    Button("Uninstall", role: .destructive) { isConfirmingUninstall = true }
                        .buttonStyle(.bordered)
                        .disabled(model.isWorking)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadInstalledSkillContent(skill.name) }
        .safeAreaInset(edge: .bottom) { SkillsHubOperationBanner(model: model) }
        .confirmationDialog(
            String(localized: "Uninstall “\(skill.name)”?"),
            isPresented: $isConfirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstall(skill.name) } }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(skill.name)
                .font(.title2.weight(.bold))
            if let description = skill.description {
                Text(description)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                SkillsHubBadge(text: SkillsHubLabels.provenance(skill.provenance ?? ""))
                if let trust = lock?.trustLevel {
                    SkillsHubBadge(text: SkillsHubLabels.trust(trust))
                }
                if let verdict = lock?.scanVerdict {
                    SkillsHubBadge(text: SkillsHubLabels.verdict(verdict))
                }
                SkillsHubBadge(text: String(localized: skill.enabled ? "Enabled" : "Disabled"))
            }
        }
    }

    @ViewBuilder
    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "SKILL.md")
                .font(.headline)
            switch contentState {
            case .loaded:
                if let markdown = installedContent?.markdown, !markdown.isEmpty {
                    MarkdownRenderer(content: markdown)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("This skill has no SKILL.md to preview.")
                        .foregroundStyle(.secondary)
                }
            case .failed(let problem):
                SkillsHubProblemView(title: String(localized: "Could Not Load Skill"), problem: problem) {
                    Task { await model.loadInstalledSkillContent(skill.name, force: true) }
                }
            case .idle, .loading:
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            }
        }
    }

    private var authenticationProblemIsPresented: Binding<Bool> {
        Binding(get: { model.authenticationProblem != nil }, set: { if !$0 { model.authenticationProblem = nil } })
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
