#if os(iOS)
import SwiftUI

struct ClubNotesScreen: View {
    enum Source {
        case personal
        case reading(clubID: String, read: ClubRead, checkpoints: [ClubCheckpoint])

        var title: String {
            switch self {
            case .personal: "My Club Notes"
            case .reading: "Reading Notes"
            }
        }

        var path: String {
            switch self {
            case .personal: "me/notes"
            case .reading(let clubID, let read, _): "clubs/\(clubID)/reads/\(read.id)/notes"
            }
        }

        var isPersonal: Bool {
            if case .personal = self { return true }
            return false
        }

        var checkpoints: [ClubCheckpoint] {
            if case .reading(_, _, let checkpoints) = self { return checkpoints }
            return []
        }
    }

    let store: ClubsStore
    let account: ClubAccount
    let source: Source

    @State private var notes: [ClubReadingNote] = []
    @State private var before: String?
    @State private var revealed = false
    @State private var loaded = false
    @State private var activeRequest: UUID?
    @State private var deleting = false
    @State private var error: String?
    @State private var editor: Editor?
    @State private var noteToDelete: ClubReadingNote?

    private var loading: Bool { activeRequest != nil }

    private enum Editor: Identifiable {
        case new, edit(ClubReadingNote)

        var note: ClubReadingNote? {
            if case .edit(let note) = self { return note }
            return nil
        }

        var id: String { note?.id ?? "new" }
    }

    var body: some View {
        ClubPage {
            switch source {
            case .personal:
                ClubHeading(overline: "Book Clubs", title: source.title)
            case .reading(_, let read, _):
                ClubHeading(overline: source.title, title: read.title)
                readingActions
            }
            if let error { ClubErrorLine(message: error) }
            if !loaded {
                if error == nil || loading {
                    ProgressView().accessibilityLabel("Loading notes")
                } else {
                    Button("Retry") { Task { await load() } }
                }
            } else if notes.isEmpty {
                ClubPanel {
                    Text(source.isPersonal ? "You haven’t saved a club note yet." : "No reading notes yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(notes) { note in notePanel(note) }
            }
            if let before {
                Button("Load Older Notes") { Task { await load(before: before) } }
                    .buttonStyle(.bordered)
                    .disabled(loading || deleting)
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editor) { editor in
            ClubReadingNoteEditor(store: store, path: source.path, checkpoints: source.checkpoints, note: editor.note) {
                Task { await load() }
            }
        }
        .alert("Delete this note?", isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }), presenting: noteToDelete) { note in
            Button("Delete", role: .destructive) { Task { await delete(note) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var readingActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { noteActions }
            VStack(alignment: .leading, spacing: 12) { noteActions }
        }
        .disabled(loading || deleting)
    }

    private var noteActions: some View {
        Group {
            Button("Add Note", systemImage: "square.and.pencil") { editor = .new }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clubs-add-note")
            if !source.checkpoints.isEmpty {
                Button(revealed ? "Hide Checkpoint Spoilers" : "Show Checkpoint Spoilers",
                       systemImage: revealed ? "eye.slash" : "eye") {
                    revealed.toggle()
                    notes = []
                    before = nil
                    loaded = false
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clubs-reveal-note-spoilers")
            }
        }
    }

    private func notePanel(_ note: ClubReadingNote) -> some View {
        ClubPanel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.isPersonal ? note.bookTitle : note.authorName).font(.headline)
                    Text(note.updatedAt, format: .dateTime.month().day().year())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if note.authorID == account.id {
                    Menu {
                        if !source.isPersonal {
                            Button("Edit Note", systemImage: "pencil") { editor = .edit(note) }
                        }
                        Button("Delete Note", systemImage: "trash", role: .destructive) { noteToDelete = note }
                    } label: {
                        Image(systemName: "ellipsis.circle").padding(8)
                    }
                    .accessibilityLabel("Note actions")
                    .disabled(loading || deleting)
                }
            }
            if let checkpoint = source.checkpoints.first(where: { $0.id == note.checkpointID }) {
                Label(checkpoint.label, systemImage: "flag")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(note.body).textSelection(.enabled)
            if note.authorID == account.id {
                Label(note.visibility.title, systemImage: note.visibility == .private ? "lock" : "person.2")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load(before cursor: String? = nil) async {
        guard !deleting, cursor == nil || !loading else { return }
        let request = UUID()
        activeRequest = request
        error = nil
        defer { if activeRequest == request { activeRequest = nil } }
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "before", value: cursor)) }
        if revealed { query.append(URLQueryItem(name: "revealSpoilers", value: "true")) }
        do {
            let page: ClubReadingNotesPage = try await store.request(source.path, query: query)
            guard activeRequest == request else { return }
            if cursor == nil { notes = page.notes }
            else { notes.append(contentsOf: page.notes) }
            before = page.before
            loaded = true
        } catch {
            if activeRequest == request, !Task.isCancelled, !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(_ note: ClubReadingNote) async {
        guard !deleting else { return }
        activeRequest = nil
        deleting = true
        error = nil
        defer { deleting = false }
        do {
            try await store.change("\(source.path)/\(note.id)", method: "DELETE")
            notes.removeAll { $0.id == note.id }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}

private struct ClubReadingNoteEditor: View {
    let store: ClubsStore
    let path: String
    let checkpoints: [ClubCheckpoint]
    let note: ClubReadingNote?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var visibility: ClubReadingNote.Visibility
    @State private var checkpointID: String?
    @State private var saving = false
    @State private var error: String?

    init(store: ClubsStore, path: String, checkpoints: [ClubCheckpoint], note: ClubReadingNote?, onSaved: @escaping () -> Void) {
        self.store = store
        self.path = path
        self.checkpoints = checkpoints
        self.note = note
        self.onSaved = onSaved
        _text = State(initialValue: note?.body ?? "")
        _visibility = State(initialValue: note?.visibility ?? .private)
        _checkpointID = State(initialValue: checkpoints.first(where: { $0.id == note?.checkpointID })?.id)
    }

    private var normalizedBody: String { text.clubTrimmed.precomposedStringWithCanonicalMapping }
    private var tooLong: Bool { normalizedBody.unicodeScalars.count > 3000 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Write a reading note", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("clubs-note-body")
                    if tooLong { ClubErrorLine(message: "Notes can contain up to 3,000 characters.") }
                }
                Section {
                    Picker("Visibility", selection: $visibility) {
                        Text(ClubReadingNote.Visibility.private.title).tag(ClubReadingNote.Visibility.private)
                        Text(ClubReadingNote.Visibility.club.title).tag(ClubReadingNote.Visibility.club)
                    }
                    .accessibilityIdentifier("clubs-note-visibility")
                    if !checkpoints.isEmpty {
                        Picker("Checkpoint", selection: $checkpointID) {
                            Text("None").tag(nil as String?)
                            ForEach(checkpoints) { checkpoint in
                                Text(checkpoint.label).tag(Optional(checkpoint.id))
                            }
                        }
                        .accessibilityIdentifier("clubs-note-checkpoint")
                    }
                } footer: {
                    if visibility == .private {
                        Text("Only you can see this note.")
                    } else if checkpointID != nil {
                        Text("Members can see this note when they complete the checkpoint or choose to reveal spoilers.")
                    } else {
                        Text("Club members can see this note as soon as you save it.")
                    }
                }
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle(note == nil ? "New Reading Note" : "Edit Reading Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || normalizedBody.isEmpty || tooLong)
                        .accessibilityIdentifier("clubs-note-save")
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        let draft = Draft(body: normalizedBody, visibility: visibility, checkpointID: checkpointID)
        do {
            if let note {
                try await store.change("\(path)/\(note.id)", method: "PATCH", body: draft)
            } else {
                let _: ClubsAPI.ID = try await store.request(path, method: "POST", body: draft)
            }
            onSaved()
            dismiss()
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private struct Draft: Encodable {
        let body: String
        let visibility: ClubReadingNote.Visibility
        let checkpointID: String?
    }
}

private struct ClubReadingNote: Decodable, Identifiable {
    enum Visibility: String, Codable {
        case `private`, club

        var title: String {
            switch self {
            case .private: "Private"
            case .club: "Shared with club"
            }
        }
    }

    let id: String
    let authorID: String
    let authorName: String
    let bookTitle: String
    let checkpointID: String?
    let body: String
    let visibility: Visibility
    let updatedAt: Date
}

private struct ClubReadingNotesPage: Decodable {
    let notes: [ClubReadingNote]
    let before: String?
}
#endif
