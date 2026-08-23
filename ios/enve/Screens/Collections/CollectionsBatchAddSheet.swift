import SwiftUI

struct CollectionsBatchAddSheet: View {
    let books: [Book]

    @Environment(EnveEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hearth) private var hearth

    private let store = UserCollectionStore.shared

    @State private var newCollectionName = ""

    private var selectedBookIDs: Set<String> {
        Set(books.map(\.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                createCollection

                if store.collections.isEmpty {
                    Text("Create a shelf above to gather these books.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Overline("Your shelves")
                        ForEach(store.collections) { collection in
                            collectionRow(collection)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .hearthPresentationBackground()
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Overline("Batch action")
                Text("Add to a shelf")
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(books.count == 1 ? "1 chosen book" : "\(books.count) chosen books")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            Spacer()
            GlyphButton(systemImage: "xmark", size: 40, glyphSize: 13, label: "Close") {
                dismiss()
            }
        }
    }

    private var createCollection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline("New shelf")
            HStack(spacing: 10) {
                TextField("Shelf name", text: $newCollectionName)
                    .font(.hearthUI(15))
                    .foregroundStyle(hearth.text)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(create)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background {
                        HearthChromeBackground(
                            shape: .rounded(14),
                            fill: hearth.bgElevated,
                            stroke: hearth.hairline,
                            tint: hearth.bgElevated
                        )
                    }

                Button(action: create) {
                    Image(systemName: "plus")
                        .font(.hearthUI(16, weight: .semibold))
                        .foregroundStyle(canCreate ? hearth.readableOnEmber : hearth.textTertiary)
                        .frame(width: 46, height: 46)
                        .background {
                            HearthChromeBackground(
                                shape: .rounded(14),
                                fill: canCreate ? hearth.ember : hearth.bgElevated,
                                stroke: canCreate ? hearth.ember : hearth.hairline,
                                tint: canCreate ? hearth.ember : hearth.bgElevated
                            )
                        }
                }
                .buttonStyle(PressableStyle())
                .disabled(!canCreate)
                .accessibilityLabel("Create shelf and add chosen books")
            }
        }
    }

    private func collectionRow(_ collection: Collection) -> some View {
        let containsAll = selectedBookIDs.isSubset(of: Set(collection.books))
        return Button {
            guard !containsAll else { return }
            let added = engine.library.addBooks(books, to: collection)
            if added > 0 {
                PlatformHaptics.impact(.light)
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: collection.iconName)
                    .font(.hearthUI(16, weight: .semibold))
                    .foregroundStyle(containsAll ? hearth.readableOnEmber : hearth.ember)
                    .frame(width: 42, height: 42)
                    .background {
                        Circle().fill(containsAll ? hearth.ember : hearth.bg)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.name)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text(collection.books.count == 1 ? "1 book" : "\(collection.books.count) books")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                Image(systemName: containsAll ? "checkmark.circle.fill" : "plus.circle")
                    .font(.hearthUI(19, weight: .medium))
                    .foregroundStyle(containsAll ? hearth.ember : hearth.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .background {
                HearthChromeBackground(
                    shape: .rounded(17),
                    fill: hearth.bgElevated,
                    stroke: containsAll ? hearth.ember.opacity(0.65) : hearth.hairline,
                    tint: hearth.bgElevated
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(containsAll)
        .accessibilityLabel(
            containsAll ? "\(collection.name), already contains all chosen books" : "Add chosen books to \(collection.name)"
        )
    }

    private var canCreate: Bool {
        !newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard engine.library.createCollection(named: newCollectionName, books: books) != nil else { return }
        newCollectionName = ""
        PlatformHaptics.impact(.light)
    }
}
