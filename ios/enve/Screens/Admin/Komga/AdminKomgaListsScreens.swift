import SwiftUI

struct AdminKomgaReadListsScreen: View {
    let model: AdminKomgaModel

    @Environment(\.hearth) private var hearth
    @State private var showingCreate = false
    @State private var pendingDelete: KomgaReadList?

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Read lists") {
            SourcesCard {
                HStack {
                    Overline("\(model.readLists.count) lists")
                    Spacer()
                    GlyphButton(systemImage: "plus", size: 40, glyphSize: 15, label: "New read list") {
                        showingCreate = true
                    }
                }
                if model.readLists.isEmpty {
                    AdminEmptyText(
                        model.isLoading
                            ? "Fetching the lists…"
                            : "No read lists yet. Create one to gather books in any order."
                    )
                } else {
                    ForEach(model.readLists) { list in
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.ember)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name)
                                    .font(.hearthUI(15, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                if let summary = list.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.hearthCaption)
                                        .foregroundStyle(hearth.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if let count = list.bookIds?.count {
                                Text("\(count) books")
                                    .font(.hearthUI(11))
                                    .foregroundStyle(hearth.textTertiary)
                            }
                            GlyphButton(systemImage: "trash", size: 40, glyphSize: 14, label: "Delete \(list.name)") {
                                pendingDelete = list
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            AdminKomgaCreateReadListSheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .alert(
            "Delete this read list",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let list = pendingDelete {
                    Task { await model.deleteReadList(list) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("“\(pendingDelete?.name ?? "")” will be gone from the server. The books stay.")
        }
        .refreshable { await model.refreshAll() }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }
}

struct AdminKomgaCollectionsScreen: View {
    let model: AdminKomgaModel

    @Environment(\.hearth) private var hearth
    @State private var showingCreate = false
    @State private var pendingDelete: KomgaCollectionSummary?

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Collections") {
            SourcesCard {
                HStack {
                    Overline("\(model.collections.count) collections")
                    Spacer()
                    GlyphButton(systemImage: "plus", size: 40, glyphSize: 15, label: "New collection") {
                        showingCreate = true
                    }
                }
                if model.collections.isEmpty {
                    AdminEmptyText(
                        model.isLoading
                            ? "Fetching the collections…"
                            : "No collections yet. Create one to gather series together."
                    )
                } else {
                    ForEach(model.collections) { collection in
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.down.right")
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.ember)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collection.name)
                                    .font(.hearthUI(15, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                HStack(spacing: 6) {
                                    if collection.ordered == true {
                                        AdminTag(text: "Ordered")
                                    }
                                    if let count = collection.seriesIds?.count {
                                        Text("\(count) series")
                                            .font(.hearthUI(11))
                                            .foregroundStyle(hearth.textTertiary)
                                    }
                                }
                            }
                            Spacer()
                            GlyphButton(systemImage: "trash", size: 40, glyphSize: 14, label: "Delete \(collection.name)") {
                                pendingDelete = collection
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            AdminKomgaCreateCollectionSheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .alert(
            "Delete this collection",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let collection = pendingDelete {
                    Task { await model.deleteCollection(collection) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("“\(pendingDelete?.name ?? "")” will be gone from the server. The series stay.")
        }
        .refreshable { await model.refreshAll() }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }
}

struct AdminKomgaCreateReadListSheet: View {
    let model: AdminKomgaModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""

    var body: some View {
        AdminSheet(
            title: "A new read list",
            confirmTitle: "Create",
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            onConfirm: {
                Task {
                    await model.createReadList(
                        name: name.trimmingCharacters(in: .whitespaces),
                        summary: summary.isEmpty ? nil : summary
                    )
                }
                dismiss()
            }
        ) {
            SourcesField(label: "Name", text: $name)
            SourcesField(label: "Summary (optional)", text: $summary)
        }
    }
}

struct AdminKomgaCreateCollectionSheet: View {
    let model: AdminKomgaModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ordered = false

    var body: some View {
        AdminSheet(
            title: "A new collection",
            confirmTitle: "Create",
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            onConfirm: {
                Task {
                    await model.createCollection(name: name.trimmingCharacters(in: .whitespaces), ordered: ordered)
                }
                dismiss()
            }
        ) {
            SourcesField(label: "Name", text: $name)
            SourcesToggleRow(
                title: "Ordered",
                subtitle: "Ordered collections keep series in the order you add them.",
                isOn: $ordered
            )
        }
    }
}
