#if os(iOS)
import SwiftUI

struct ClubActivityFeedScreen: View {
    let store: ClubsStore
    let onOpen: (String, ClubDiscussionLink?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var events: [ClubFeedEvent] = []
    @State private var cursor: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ClubPage {
                ClubHeading(overline: "Book Clubs", title: "Club Feed")
                if let error {
                    ClubErrorLine(message: error)
                    Button("Refresh Feed") { Task { await load() } }
                        .disabled(loading)
                }
                if loading && !loaded {
                    ProgressView().accessibilityLabel("Loading club activity")
                } else if loaded && events.isEmpty {
                    Text("New reads, discussions, and check-ins from your clubs will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    Button { onOpen(event.clubID, event.discussion) } label: {
                        ClubPanel {
                            Label(event.clubName, systemImage: event.icon)
                                .font(.subheadline.weight(.semibold))
                            Text(event.summary)
                            Text(event.createdAt, style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(event.discussion == nil ? "Opens the club" : "Opens the discussion")
                    .accessibilityIdentifier("clubs-feed-event-\(event.id)")
                }
                if let cursor {
                    Button("Load Older Activity") { Task { await load(before: cursor) } }
                        .disabled(loading)
                }
            }
            .navigationTitle("Club Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load(before: String? = nil) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let query = before.map { [URLQueryItem(name: "before", value: $0)] } ?? []
            let page: ClubFeedPage = try await store.request("me/feed", query: query)
            if before == nil { events = page.events }
            else { events += page.events }
            cursor = page.before
            loaded = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ClubFeedPage: Decodable {
    let events: [ClubFeedEvent]
    let before: String?
}

private struct ClubFeedEvent: Decodable, Identifiable {
    let id: String
    let clubID: String
    let clubName: String
    let memberName: String?
    let kind: String
    let label: String
    let createdAt: Date
    let discussion: ClubDiscussionLink?

    var summary: String {
        let name = memberName ?? "A member"
        switch kind {
        case "post": return "\(name) posted about \(label)"
        case "readStarted": return "\(name) started \(label)"
        case "checkpoint": return "\(name) reached \(label)"
        case "pollClosed": return "\(name) closed the vote for \(label)"
        case "planChanged": return "\(name) updated the reading plan"
        default: return label
        }
    }

    var icon: String {
        switch kind {
        case "post": "bubble.left"
        case "checkpoint": "flag"
        case "pollClosed": "checkmark.circle"
        case "planChanged": "list.bullet"
        default: "book"
        }
    }
}
#endif
