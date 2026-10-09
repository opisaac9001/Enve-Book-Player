import SwiftUI

struct CrossProviderHistoryMatchScreen: View {
    @Environment(\.profileSession) private var capturedSession
    private var profileSession: ProfileSession { capturedSession ?? .owner }
    let source: Book

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Book] = []
    @State private var query = ""
    @State private var isSaving = false
    @State private var includeEarlierHistory = false
    @State private var errorMessage: String?

    private var filtered: [Book] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return candidates }
        return candidates.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.author?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose the matching Audiobookshelf book and account. Listening time will sync to that account. Existing ABS progress is preserved during history backfill.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                Toggle("Include earlier listening sessions", isOn: $includeEarlierHistory)
                    .font(.hearthCaption)
                Text("Earlier sessions upload only when this ABS account already has newer progress for that book.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                TextField("Search ABS books", text: $query)
                    .textFieldStyle(.roundedBorder)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.statusError)
                }
                List(filtered, id: \.stableId) { target in
                    Button {
                        Task { await choose(target) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.title)
                                .font(.hearthUI(15, weight: .semibold))
                            Text([target.author, connectionName(target.providerId)].compactMap { $0 }.joined(separator: " · "))
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                    .disabled(isSaving)
                }
                .listStyle(.plain)
            }
            .padding(.horizontal, 20)
            .hearthPresentationBackground()
            .navigationTitle("Link listening history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func connectionName(_ id: UUID) -> String? {
        profileSession.appState.providerConnections.connections.first(where: { $0.id == id })?.name
    }

    private func load() async {
        var found: [Book] = []
        for connection in profileSession.appState.providerConnections.connections
        where connection.type == .audiobookshelf && !connection.isArchived {
            found += await profileSession.appState.bookStore.books(
                source: Book.BookSource.audiobookshelf.rawValue,
                providerId: connection.id,
                mediaType: AppMediaType.audiobook.rawValue
            )
        }
        candidates = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        query = source.title
    }

    private func choose(_ target: Book) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await profileSession.crossProviderHistory.confirm(
                source: source, target: target, includeEarlierHistory: includeEarlierHistory
            )
            _ = await profileSession.crossProviderHistory.retryPending(targetConnectionId: target.providerId)
            dismiss()
        } catch {
            errorMessage = "Could not verify that book and ABS account. Check the connection and try again."
        }
    }
}
