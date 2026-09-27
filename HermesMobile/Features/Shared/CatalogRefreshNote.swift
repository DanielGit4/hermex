import SwiftUI

/// The one-line status above rows a screen already had while it asks the server
/// again: a static "Refreshing..." while the request runs, and "Couldn’t refresh"
/// with the time of the rows on screen when it failed. Nothing here animates, so
/// it is Reduce Motion safe by construction, and the rows below never wait on it.
struct CatalogRefreshNote: View {
    enum State: Equatable {
        case refreshing
        /// `since` dates the rows still on screen; `detail` is the failure, if short.
        case failed(since: Date, detail: String?)
    }

    let state: State

    var body: some View {
        switch state {
        case .refreshing:
            Label {
                Text("Refreshing...")
            } icon: {
                Image(systemName: "arrow.clockwise")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .failed(let since, let detail):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.failureTitle(since: since))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// "Couldn’t refresh. Showing data from 9:41 PM." Today's rows name only the
    /// time; older rows name their day too, relative where the system has a word.
    static func failureTitle(since: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time: String
        if calendar.isDate(since, inSameDayAs: now) {
            time = since.formatted(date: .omitted, time: .shortened)
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            time = formatter.string(from: since)
        }
        return String(localized: "Couldn’t refresh. Showing data from \(time).")
    }
}
