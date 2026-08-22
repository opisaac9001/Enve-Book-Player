import SwiftUI

struct BookOrbitCollectionEditor: View {
    let collection: Collection?
    let connections: [ServerConnection]
    let onSaved: () -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var connectionId: UUID
    @State private var name: String
    @State private var details: String
    @State private var icon: String
    @State private var syncToKobo: Bool
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    init(collection: Collection? = nil, connections: [ServerConnection], onSaved: @escaping () -> Void) {
        self.collection = collection
        self.connections = connections
        self.onSaved = onSaved
        _connectionId = State(initialValue: collection?.providerId ?? connections.first?.id ?? UUID())
        _name = State(initialValue: collection?.name ?? "")
        _details = State(initialValue: collection?.description ?? "")
        _icon = State(initialValue: collection?.serverIcon ?? "books")
        _syncToKobo = State(initialValue: collection?.syncToKobo ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                if collection == nil, connections.count > 1 {
                    Picker("BookOrbit server", selection: $connectionId) {
                        ForEach(connections) { connection in
                            Text(connection.name).tag(connection.id)
                        }
                    }
                }

                Section("Collection") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Icon", text: $icon)
                    Toggle("Sync to Kobo", isOn: $syncToKobo)
                }

                if collection != nil {
                    Section {
                        Button("Delete collection", role: .destructive) {
                            confirmDelete = true
                        }
                    } footer: {
                        Text("This permanently deletes the collection from BookOrbit. The books themselves are not deleted.")
                    }
                }
            }
            .navigationTitle(collection == nil ? "New BookOrbit collection" : "Edit collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .disabled(saving)
            .overlay {
                if saving { ProgressView() }
            }
            .alert("Delete this collection?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes \"\(name)\" from BookOrbit. Books in the collection remain in the library.")
            }
            .alert(
                "BookOrbit collection",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await engine.library.saveBookOrbitCollection(
                    connectionId: connectionId,
                    collection: collection,
                    edit: BookOrbitProvider.CollectionEdit(
                        name: name,
                        description: details.isEmpty ? nil : details,
                        icon: icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "books" : icon,
                        syncToKobo: syncToKobo
                    )
                )
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }

    private func delete() {
        guard let collection else { return }
        saving = true
        Task {
            do {
                try await engine.library.deleteBookOrbitCollection(collection)
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}

struct BookOrbitMembershipSheet: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var memberships: [BookOrbitCollectionMembership] = []
    @State private var loading = true
    @State private var pendingRemoval: BookOrbitCollectionMembership?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView("Loading collections…")
                } else if memberships.isEmpty {
                    ContentUnavailableView(
                        "No editable collections",
                        systemImage: "books.vertical",
                        description: Text("BookOrbit collection changes require an administrator account.")
                    )
                } else {
                    ForEach(memberships) { membership in
                        Button {
                            if membership.containsBook {
                                pendingRemoval = membership
                            } else {
                                update(membership, containsBook: true)
                            }
                        } label: {
                            HStack {
                                Text(membership.collection.name)
                                Spacer()
                                if membership.containsBook {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("BookOrbit collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .alert(
                "Remove from collection?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    if let membership = pendingRemoval {
                        update(membership, containsBook: false)
                    }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Remove \"\(book.title)\" from \"\(pendingRemoval?.collection.name ?? "this collection")\" on BookOrbit?")
            }
            .alert(
                "BookOrbit collections",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func load() async {
        do {
            memberships = try await engine.library.bookOrbitMemberships(for: book)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func update(_ membership: BookOrbitCollectionMembership, containsBook: Bool) {
        Task {
            do {
                try await engine.library.setBookOrbitMembership(containsBook, book: book, collection: membership.collection)
                if let index = memberships.firstIndex(where: { $0.id == membership.id }) {
                    memberships[index].containsBook = containsBook
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
