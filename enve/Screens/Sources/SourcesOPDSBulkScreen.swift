import Combine
import SwiftUI

struct SourcesOPDSBulkScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @StateObject private var service = OPDSBulkImportService()

    @State private var selectedConnectionId: UUID?
    @State private var selectedBookIds: Set<String> = []
    @State private var collectionName = ""
    @State private var isLoadingCatalog = false

    private var opdsConnections: [ServerConnection] {
        engine.sources.activeConnections(type: .opds)
    }

    private var selectedConnection: ServerConnection? {
        opdsConnections.first { $0.id == selectedConnectionId }
    }

    var body: some View {
        SettingsScaffold(
            overline: "Sources & servers",
            title: "OPDS import",
            subtitle: "Download a feed's books into a collection of their own."
        ) {
            sourceCard

            if selectedConnection != nil {
                SourcesField(label: "Collection name", text: $collectionName, placeholder: selectedConnection?.name ?? "Collection")
                catalogCard
                importBar
            }

            if let summary = service.lastSummary {
                Text(summary)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: selectedConnectionId) { _, _ in
            Task { await loadCatalog() }
        }
    }

    private var sourceCard: some View {
        SourcesCard {
            Overline("OPDS source")
            if opdsConnections.isEmpty {
                Text("Add an OPDS source first, then come back to import in bulk.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(opdsConnections) { connection in
                    SettingsChoiceRow(
                        title: connection.name,
                        caption: URL(string: connection.url)?.host ?? connection.url,
                        systemImage: "books.vertical",
                        isSelected: selectedConnectionId == connection.id
                    ) {
                        selectedConnectionId = connection.id
                    }
                }
            }
        }
    }

    private var catalogCard: some View {
        SourcesCard {
            HStack {
                Overline("The feed")
                Spacer()
                if !service.items.isEmpty {
                    Button(selectedBookIds.count == service.items.count ? "Choose some" : "All") {
                        if selectedBookIds.count == service.items.count {
                            selectedBookIds.removeAll()
                        } else {
                            selectedBookIds = Set(service.items.map(\.id))
                        }
                    }
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.ember)
                }
            }

            if isLoadingCatalog {
                HStack(spacing: 10) {
                    ProgressView().tint(hearth.ember)
                    Text("Reading the catalogue…")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else if service.items.isEmpty {
                Text("Nothing in this feed.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                ForEach(service.items) { item in
                    opdsItemRow(item)
                }
            }
        }
    }

    private func opdsItemRow(_ item: OPDSBulkImportService.ImportItem) -> some View {
        Button {
            if selectedBookIds.contains(item.id) {
                selectedBookIds.remove(item.id)
            } else {
                selectedBookIds.insert(item.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedBookIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedBookIds.contains(item.id) ? hearth.ember : hearth.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.book.title)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = item.book.author, !author.isEmpty {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    opdsStatusText(item.status)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private func opdsStatusText(_ status: OPDSBulkImportService.ImportItem.Status) -> some View {
        switch status {
        case .pending:
            EmptyView()
        case let .downloading(progress):
            Text("Downloading… \(Int(progress * 100))%")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
        case .completed:
            Label("Imported", systemImage: "checkmark.circle.fill")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.statusOK)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.statusWarn)
                .lineLimit(2)
        }
    }

    private var importBar: some View {
        EmberButton(
            title: service.isRunning ? "Importing…" : "Import \(selectedBookIds.count)",
            systemImage: service.isRunning ? nil : "arrow.down.circle",
            tint: nil
        ) {
            guard let connection = selectedConnection else { return }
            Task {
                await service.importSelected(
                    selectedIDs: selectedBookIds,
                    from: connection,
                    collectionName: collectionName.isEmpty ? connection.name : collectionName
                )
            }
        }
        .disabled(service.isRunning || selectedBookIds.isEmpty)
        .opacity(service.isRunning || selectedBookIds.isEmpty ? 0.5 : 1)
    }

    private func loadCatalog() async {
        guard let connection = selectedConnection else { return }
        isLoadingCatalog = true
        await service.loadCatalog(connection: connection)
        isLoadingCatalog = false
        selectedBookIds = []
        if collectionName.isEmpty {
            collectionName = connection.name
        }
    }
}
