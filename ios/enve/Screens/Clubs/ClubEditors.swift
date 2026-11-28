#if os(iOS)
import SwiftUI

struct ClubStartEditor: View {
    enum Input {
        case create(Book?)
        case next(clubID: String, book: Book?, nomination: ClubNomination?, pollID: String?)
    }

    let store: ClubsStore
    let input: Input
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var title = ""
    @State private var author = ""
    @State private var checkpoints: [ClubCheckpointDraft] = []
    @State private var busy = false
    @State private var error: String?

    private var isCreating: Bool { if case .create = input { true } else { false } }
    private var initialBook: Book? {
        switch input {
        case .create(let book), .next(_, let book, _, _): book
        }
    }
    private var nomination: ClubNomination? {
        if case .next(_, _, let nomination, _) = input { nomination } else { nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreating {
                    Section("Club") { TextField("Club name", text: $name).accessibilityIdentifier("clubs-name") }
                }
                Section(isCreating ? "First book (optional)" : "Book") {
                    TextField("Title", text: $title).accessibilityIdentifier("clubs-book-title")
                        .disabled(nomination != nil || initialBook != nil)
                    TextField("Author", text: $author).disabled(nomination != nil || initialBook != nil)
                }
                if !title.clubTrimmed.isEmpty {
                    Section {
                        ForEach($checkpoints) { $checkpoint in
                            ClubCheckpointFields(checkpoint: $checkpoint)
                        }
                        .onDelete { checkpoints.remove(atOffsets: $0) }
                        .onMove { checkpoints.move(fromOffsets: $0, toOffset: $1) }
                        Button("Add Checkpoint", systemImage: "plus") {
                            checkpoints.append(ClubCheckpointDraft(label: ""))
                        }
                        .disabled(checkpoints.count >= 24)
                    } header: {
                        Text("Reading plan")
                    } footer: {
                        Text("Use chapter names or parts. Dates are optional. Drag checkpoints to change their order in Edit.")
                    }
                }
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle(isCreating ? "Start a Club" : "Start a Read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                if !checkpoints.isEmpty { ToolbarItem(placement: .secondaryAction) { EditButton() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Create" : "Start") { save() }
                        .disabled(busy || (isCreating ? name.clubTrimmed.isEmpty : title.clubTrimmed.isEmpty)
                                  || checkpoints.contains { $0.label.clubTrimmed.isEmpty })
                        .accessibilityIdentifier("clubs-create-confirm")
                }
            }
            .onAppear {
                guard title.isEmpty else { return }
                title = nomination?.name ?? initialBook?.title ?? ""
                author = nomination?.author ?? initialBook?.author ?? ""
                if let initialBook { checkpoints = Self.suggested(for: initialBook) }
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let clubID: String
                let pollID: String?
                switch input {
                case .create:
                    pollID = nil
                    let draft = title.clubTrimmed.isEmpty ? nil : makeDraft(pollID: nil)
                    let result: ClubsAPI.ID = try await store.request("clubs", method: "POST", body: CreateClub(name: name, read: draft))
                    clubID = result.id
                case .next(let id, _, _, let selectedPoll):
                    clubID = id
                    pollID = selectedPoll
                    let _: ClubsAPI.ID = try await store.request("clubs/\(clubID)/reads", method: "POST", body: makeDraft(pollID: pollID))
                }
                if let initialBook,
                   let club: ClubDetails = try? await store.request("clubs/\(clubID)"), let readID = club.currentRead?.id,
                   let details: ClubReadDetails = try? await store.request("clubs/\(clubID)/reads/\(readID)") {
                    store.link(initialBook, clubID: clubID, read: details)
                }
                onSaved(clubID)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func makeDraft(pollID: String?) -> ClubReadDraft {
        ClubReadDraft(title: title, author: author.clubOptional, series: initialBook?.series, checkpoints: checkpoints, pollID: pollID)
    }

    private struct CreateClub: Encodable {
        let name: String
        let read: ClubReadDraft?
    }

    private static func suggested(for book: Book) -> [ClubCheckpointDraft] {
        guard let chapters = book.chapters?.filter({ !$0.title.clubTrimmed.isEmpty }), !chapters.isEmpty else {
            return [ClubCheckpointDraft(label: "Finish the book", trackPosition: 1)]
        }
        let count = min(4, chapters.count)
        return (1...count).map { step in
            let chapter = chapters[(step * chapters.count + count - 1) / count - 1]
            let percentage = book.duration.flatMap { $0 > 0 && chapter.end <= $0 ? chapter.end / $0 : nil }
            return ClubCheckpointDraft(label: chapter.title, chapterKey: ClubsStore.chapterKey(chapter.title).clubOptional,
                                       trackPosition: percentage)
        }
    }
}

struct ClubCheckpointFields: View {
    @Binding var checkpoint: ClubCheckpointDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Checkpoint name", text: $checkpoint.label)
            Toggle("Set a deadline", isOn: Binding(get: { checkpoint.dueAt != nil }, set: { enabled in
                checkpoint.dueAt = enabled ? Calendar.current.date(byAdding: .day, value: 7, to: .now) : nil
            }))
            if let due = checkpoint.dueAt {
                DatePicker("Due", selection: Binding(get: { checkpoint.dueAt ?? due }, set: { checkpoint.dueAt = $0 }))
            }
        }
    }
}

struct ClubCheckpointEditor: View {
    let store: ClubsStore
    let clubID: String
    let readID: String
    let checkpoint: ClubCheckpoint?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ClubCheckpointDraft(label: "")
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                ClubCheckpointFields(checkpoint: $draft)
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle(checkpoint == nil ? "Add Checkpoint" : "Edit Checkpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(busy || draft.label.clubTrimmed.isEmpty)
                }
            }
            .onAppear {
                if let checkpoint { draft = ClubCheckpointDraft(label: checkpoint.label, dueAt: checkpoint.dueAt) }
            }
        }
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let path = "clubs/\(clubID)/reads/\(readID)/checkpoints"
                if let checkpoint {
                    try await store.change("\(path)/\(checkpoint.id)", method: "PATCH", body: draft)
                } else {
                    draft.chapterKey = ClubsStore.chapterKey(draft.label).clubOptional
                    let _: ClubsAPI.ID = try await store.request(path, method: "POST", body: draft)
                }
                onSaved()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ClubCopyPicker: View {
    let session: ProfileSession
    var read: ClubRead? = nil
    let onPick: (Book) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matches: [Book] {
        let books = session.appState.allBooks.lazy.filter { $0.mediaType == .audiobook || $0.mediaType == .ebook }
        if !search.clubTrimmed.isEmpty {
            return Array(books.filter { $0.title.localizedStandardContains(search) || ($0.author?.localizedStandardContains(search) ?? false) }.prefix(80))
        }
        if let read {
            return Array(books.filter { ClubsStore.chapterKey($0.title) == ClubsStore.chapterKey(read.title) }.prefix(20))
        }
        return Array(books.prefix(30))
    }

    var body: some View {
        NavigationStack {
            List {
                if matches.isEmpty {
                    Text("Search your library by title or author.").foregroundStyle(.secondary)
                }
                ForEach(matches, id: \.uniqueId) { book in
                    Button {
                        onPick(book)
                        dismiss()
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(book.title)
                                if let author = book.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: { Image(systemName: book.mediaType == .ebook ? "book" : "headphones") }
                    }
                }
            }
            .navigationTitle(read == nil ? "Choose a Book" : "Choose Your Copy")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title or author")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
#endif
