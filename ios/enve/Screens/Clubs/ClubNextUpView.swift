#if os(iOS)
import SwiftUI

struct ClubNextUpView: View {
    let store: ClubsStore
    let account: ClubAccount
    let clubID: String
    let isHost: Bool
    let startWinner: (ClubNomination, String) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var next: ClubNextUp?
    @State private var sheet: Sheet?
    @State private var closing: ClubPoll?
    @State private var error: String?
    @State private var busy = false

    private enum Sheet: String, Identifiable {
        case nominate, poll
        var id: String { rawValue }
    }

    private var base: String { "clubs/\(clubID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let next {
                ClubPanel {
                    Text("What should we read next?").font(.headline)
                    Button("Nominate a Book", systemImage: "plus") { sheet = .nominate }.buttonStyle(.borderedProminent)
                    if isHost, next.nominations.count >= 2, !next.polls.contains(where: { $0.closedAt == nil }) {
                        Button("Start a Vote", systemImage: "chart.bar") { sheet = .poll }.buttonStyle(.bordered)
                    }
                }
                ForEach(next.polls) { poll in pollCard(poll, nominations: next.nominations) }
                ClubPanel {
                    Text("Nominations").font(.headline).accessibilityAddTraits(.isHeader)
                    if next.nominations.isEmpty { Text("Add the first suggestion.").foregroundStyle(.secondary) }
                    ForEach(next.nominations) { nomination in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(nomination.name).font(.subheadline.weight(.semibold))
                            if let author = nomination.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                            if let member = nomination.memberName { Text("Suggested by \(member)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else if error == nil {
                ProgressView().accessibilityLabel("Loading nominations and votes")
            }
            if let error {
                ClubErrorLine(message: error)
                Button("Refresh Votes") { Task { await load() } }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(25))
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .nominate:
                ClubNominationEditor(store: store, path: base + "/nominations") { Task { await load() } }
            case .poll:
                ClubPollEditor(store: store, path: base + "/polls", nominations: next?.nominations ?? []) { Task { await load() } }
            }
        }
        .confirmationDialog("Close this vote?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { poll in
            if poll.leaders.count == 1 {
                Button("Close Vote") { close(poll, winner: nil) }
            } else {
                ForEach(next?.nominations.filter { poll.leaders.contains($0.id) } ?? []) { nomination in
                    Button("Choose \(nomination.name)") { close(poll, winner: nomination.id) }
                }
            }
        } message: { poll in
            Text(poll.leaders.count == 1 ? "The book with the most votes will win." : "These books are tied. Choose one to break the tie.")
        }
    }

    private func pollCard(_ poll: ClubPoll, nominations: [ClubNomination]) -> some View {
        ClubPanel {
            Text(poll.name).font(.headline)
            if let date = poll.closedAt {
                Text("Closed \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            } else if let date = poll.closesAt {
                Text(date > .now ? "Vote by \(date.formatted(date: .abbreviated, time: .shortened))" : "Voting ended")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(nominations.filter { poll.optionIDs.contains($0.id) }) { nomination in
                let votes = poll.votes.filter { $0.nominationID == nomination.id }
                let selected = votes.contains { $0.accountID == account.id }
                VStack(alignment: .leading, spacing: 5) {
                    if poll.isAcceptingVotes {
                        Button {
                            vote(poll, nomination: nomination)
                        } label: {
                            Label(nomination.name, systemImage: selected ? "checkmark.circle.fill" : "circle")
                        }
                        .disabled(busy)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    } else {
                        Label(nomination.name, systemImage: poll.winnerID == nomination.id ? "trophy.fill" : "book")
                    }
                    Text(votes.isEmpty ? "No votes yet" : votes.map(\.memberName).sorted().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            if isHost {
                if poll.closedAt == nil {
                    Button("Close Vote") { closing = poll }.buttonStyle(.bordered).disabled(busy)
                } else if poll.startedReadID == nil, let winner = nominations.first(where: { $0.id == poll.winnerID }) {
                    Button("Start Winning Book") { startWinner(winner, poll.id) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func load() async {
        do {
            next = try await store.request(base + "/next")
            error = nil
        } catch is CancellationError {
        } catch let error as ClubsResponseError where error.status == 404 {
            next = nil
            self.error = error.localizedDescription
        } catch { self.error = error.localizedDescription }
    }

    private func vote(_ poll: ClubPoll, nomination: ClubNomination) {
        update { try await store.change("\(base)/polls/\(poll.id)/vote", body: ["nominationID": nomination.id]) }
    }

    private func close(_ poll: ClubPoll, winner: String?) {
        update { try await store.change("\(base)/polls/\(poll.id)/close", method: "POST", body: ["winnerID": winner]) }
    }

    private func update(_ change: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await change(); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ClubNominationEditor: View {
    let store: ClubsStore
    let path: String
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var author = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Book title", text: $name)
                TextField("Author (optional)", text: $author)
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle("Nominate a Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Nominate") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let _: ClubsAPI.ID = try await store.request(path, method: "POST", body: ["name": name, "author": author])
                                onSaved()
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(busy || name.clubOptional == nil)
                }
            }
        }
    }
}

private struct ClubPollEditor: View {
    let store: ClubsStore
    let path: String
    let nominations: [ClubNomination]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Next club read"
    @State private var due: Date?
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Vote") {
                    TextField("Name", text: $name)
                    Toggle("Set a closing date", isOn: Binding(get: { due != nil }, set: { due = $0 ? .now.addingTimeInterval(86_400) : nil }))
                    if let date = due {
                        DatePicker("Closes", selection: Binding(get: { due ?? date }, set: { due = $0 }), in: Date.now...)
                    }
                }
                Section("Choose 2 to 12 books") {
                    ForEach(nominations) { nomination in
                        Toggle(nomination.name, isOn: Binding(get: { selected.contains(nomination.id) }, set: { enabled in
                            if enabled { selected.insert(nomination.id) } else { selected.remove(nomination.id) }
                        }))
                        .disabled(selected.count >= 12 && !selected.contains(nomination.id))
                    }
                }
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle("Start a Vote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { submit() }.disabled(busy || selected.count < 2 || name.clubOptional == nil)
                }
            }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let _: ClubsAPI.ID = try await store.request(path, method: "POST", body: Draft(name: name, optionIDs: selected.sorted(), closesAt: due))
                onSaved()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private struct Draft: Encodable { let name: String; let optionIDs: [String]; let closesAt: Date? }
}
#endif
