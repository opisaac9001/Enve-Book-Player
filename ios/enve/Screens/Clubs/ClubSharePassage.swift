#if os(iOS)
import SwiftUI

struct ClubSharePassage: View {
    let store: ClubsStore
    let book: Book
    let annotation: ReaderAnnotation
    @Environment(\.dismiss) private var dismiss
    @State private var clubs: [ClubSummary] = []
    @State private var selectedClub = ""
    @State private var selectedThread = "general"
    @State private var read: ClubReadDetails?
    @State private var comment = ""
    @State private var excerpt = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Passage") {
                    TextField("Excerpt", text: $excerpt, axis: .vertical).lineLimit(2...5)
                    TextField("Add a comment (optional)", text: $comment, axis: .vertical)
                    Text("The excerpt and your comment will be visible to club members.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !clubs.isEmpty {
                    Picker("Club", selection: $selectedClub) {
                        ForEach(clubs) { club in Text(club.name).tag(club.id) }
                    }
                    if let read {
                        Picker("Discussion", selection: $selectedThread) {
                            Text("General Discussion").tag("general")
                            ForEach(read.checkpoints) { checkpoint in Text(checkpoint.label).tag(checkpoint.id) }
                        }
                        if selectedThread == "general" {
                            Text("General discussion is visible immediately. Choose a checkpoint for a spoiler reveal.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if loaded && error == nil {
                    Text("Choose this copy in a club’s current reading plan before sharing a passage.")
                        .foregroundStyle(.secondary)
                }
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle("Share with a Club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") { share() }
                        .disabled(busy || read == nil || excerpt.clubOptional == nil || excerpt.count > 600)
                }
            }
            .task {
                excerpt = String(annotation.text.prefix(600))
                do {
                    let linked = Set(store.linkedCopies(for: book).map(\.clubID))
                    let all: [ClubSummary] = try await store.request("clubs")
                    clubs = all.filter { linked.contains($0.id) && $0.currentTitle != nil }
                    selectedClub = clubs.first?.id ?? ""
                    loaded = true
                } catch is CancellationError {
                } catch { self.error = error.localizedDescription }
            }
            .task(id: selectedClub) { await readPlan() }
        }
    }

    private func readPlan() async {
        let clubID = selectedClub
        read = nil
        selectedThread = "general"
        guard !clubID.isEmpty else { return }
        do {
            let club: ClubDetails = try await store.request("clubs/\(clubID)")
            guard let current = club.currentRead, store.copy(for: current.id)?.bookID == book.uniqueId else { return }
            let detail: ClubReadDetails = try await store.request("clubs/\(clubID)/reads/\(current.id)")
            guard clubID == selectedClub else { return }
            read = detail
            if let chapter = annotation.chapterTitle {
                let key = ClubsStore.chapterKey(chapter)
                selectedThread = detail.checkpoints.first { $0.chapterKey == key || ClubsStore.chapterKey($0.label) == key }?.id ?? "general"
            }
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func share() {
        guard let read else { return }
        busy = true
        let path = "clubs/\(selectedClub)/reads/\(read.read.id)/threads/\(selectedThread)"
        Task {
            defer { busy = false }
            do {
                let _: ClubsAPI.ID = try await store.request(path, method: "POST", body: [
                    "body": comment.clubOptional, "passage": excerpt.clubOptional, "passageChapter": annotation.chapterTitle,
                ])
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
