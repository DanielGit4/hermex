import SwiftUI

/// Installing a catalog plugin: one switch, then a review that repeats the repository, pin,
/// tier and every capability before Install. The install can run for minutes on the host,
/// so the sheet closes once it starts and the banner follows it.
struct PluginInstallSheet: View {
    let model: PluginCatalogViewModel
    let entry: PluginCatalogEntry

    @Environment(\.dismiss) private var dismiss
    @State private var enable = true
    @State private var isReviewing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable after install", isOn: $enable)
                } footer: {
                    Text("An enabled plugin loads into Hermes right away when it can, otherwise after a restart.")
                }
            }
            .navigationTitle(entry.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { isReviewing = true }
                        .disabled(!model.canInstall(entry))
                }
            }
            .navigationDestination(isPresented: $isReviewing) { review }
        }
    }

    private var review: some View {
        List {
            Section {
                MCPValueRow(title: "Name", value: entry.name)
            }
            PluginReviewSections(entry: entry)
            Section {
                LabeledContent("State after install") {
                    Text(enable ? String(localized: "Enabled") : String(localized: "Disabled"))
                }
            } footer: {
                Text("Hermes clones this commit on the host, scans it, installs its Python dependencies and runs its code. Install only plugins you trust.")
            }
            Section {
                Button(action: install) {
                    Text("Install on Hermes Host")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canInstall(entry))
            }
        }
        .navigationTitle("Review")
    }

    /// The install belongs to the catalog model, so it keeps running after the sheet closes.
    private func install() {
        let entry = entry
        let enable = enable
        Task { await model.install(entry, enable: enable) }
        dismiss()
    }
}
