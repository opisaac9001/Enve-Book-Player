import Combine
import SwiftUI

/// Browse catalog structure and acquisitions that library import cannot represent.
struct SourcesOPDSBrowseScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.openURL) private var openURL

    @State private var browser = OPDSCatalogBrowser()
    @StateObject private var importer = OPDSBulkImportService()

    @State private var selectedConnectionId: UUID?
    @State private var collectionName = ""
    @State private var searchField = ""
    @State private var signIn: OPDSAuthenticationDocument?

    init(connectionId: UUID? = nil) {
        _selectedConnectionId = State(initialValue: connectionId)
    }

    private var opdsConnections: [ServerConnection] {
        engine.sources.activeConnections(type: .opds)
    }

    private var selectedConnection: ServerConnection? {
        opdsConnections.first { $0.id == selectedConnectionId }
    }

    var body: some View {
        SettingsScaffold(
            overline: "Sources & servers",
            title: "OPDS catalogue",
            subtitle: "Browse a feed, search it, and download what it offers."
        ) {
            sourceCard

            if selectedConnection != nil {
                if let challenge = browser.signInChallenge {
                    signInCard(challenge)
                }
                accountCard
                if let message = browser.errorMessage {
                    noticeCard(message)
                }
                breadcrumbCard
                if browser.canSearch { searchCard }
                navigationCard
                facetsCard
                groupsSection
                publicationsCard
                paginationCard
                importBar
            }

            if let summary = importer.lastSummary {
                Text(summary)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: selectedConnectionId) { _, _ in
            Task { await openSelectedConnection() }
        }
        .sheet(item: $signIn) { document in
            OPDSSignInSheet(document: document, connection: selectedConnection) {
                guard let connection = selectedConnection else { return }
                Task { await browser.reloadAfterSignIn(with: connection) }
            }
            .enveEnvironment()
            .hearthPresentationBackground()
            .presentationDetents([.medium, .large])
        }
        .task {
            if selectedConnectionId == nil {
                selectedConnectionId = opdsConnections.first?.id
            } else {
                await openSelectedConnection()
            }
        }
    }

    // MARK: Source

    private var sourceCard: some View {
        SourcesCard {
            Overline("OPDS source")
            if opdsConnections.isEmpty {
                Text("Add an OPDS source first, then come back to browse it.")
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

    @ViewBuilder
    private func signInCard(_ document: OPDSAuthenticationDocument) -> some View {
        SourcesCard {
            Overline("Sign in required")
            Text(document.title)
                .font(.hearthBody.weight(.medium))
                .foregroundStyle(hearth.text)
            if let summary = document.summary, !summary.isEmpty {
                Text(summary)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if document.supportedFlows.isEmpty {
                Text("This catalogue asks for a sign-in Enve does not support.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                EmberButton(title: "Sign in", systemImage: "person.badge.key", tint: nil) {
                    signIn = document
                }
            }
        }
    }

    @ViewBuilder
    private var accountCard: some View {
        if let account = browser.signedInAccount {
            SourcesCard {
                Overline("Signed in")
                Text(account)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Button("Sign out") {
                    Task { await browser.signOut() }
                }
                .font(.hearthCaption.weight(.medium))
                .foregroundStyle(hearth.ember)
            }
        }
    }

    private func noticeCard(_ message: String) -> some View {
        SourcesCard {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.hearthCaption)
                .foregroundStyle(hearth.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Position

    private var breadcrumbCard: some View {
        SourcesCard {
            HStack(spacing: 10) {
                if browser.canGoBack {
                    Button {
                        Task { await browser.goBack() }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.hearthCaption.weight(.medium))
                            .foregroundStyle(hearth.ember)
                    }
                    .buttonStyle(PressableStyle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.title)
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let trail = trailText {
                        Text(trail)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if browser.isLoading {
                    ProgressView().tint(hearth.ember)
                } else {
                    GlyphButton(systemImage: "arrow.clockwise", size: 34, glyphSize: 13, label: "Reload") {
                        Task { await browser.reload() }
                    }
                }
            }
        }
    }

    private var trailText: String? {
        let names = browser.trail.dropLast().map(\.title)
        return names.isEmpty ? nil : names.joined(separator: " › ")
    }

    // MARK: Search

    private var searchCard: some View {
        SourcesCard {
            Overline("Search this catalogue")
            SourcesField(label: "Terms", text: $searchField, placeholder: "Title, author, subject")
            HStack(spacing: 10) {
                EmberButton(title: "Search", systemImage: "magnifyingglass", tint: nil) {
                    Task { await browser.search(for: searchField) }
                }
                .disabled(searchField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(searchField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)

                if browser.isSearchResult {
                    Button("Clear") {
                        searchField = ""
                        Task { await browser.clearSearch() }
                    }
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    // MARK: Structure

    @ViewBuilder
    private var navigationCard: some View {
        let navigation = browser.page?.navigation ?? []
        let catalogs = browser.page?.catalogs ?? []
        let webCatalogs = browser.page?.webCatalogs ?? []
        if !navigation.isEmpty || !catalogs.isEmpty || !webCatalogs.isEmpty {
            SourcesCard {
                Overline("Browse")
                ForEach(navigation) { entry in
                    Button {
                        Task { await browser.descend(to: entry.url, title: entry.title) }
                    } label: {
                        SettingsLinkRow(
                            title: entry.title,
                            subtitle: entry.summary,
                            detail: entry.count.map(String.init),
                            systemImage: "folder"
                        )
                    }
                    .buttonStyle(PressableStyle())
                }
                ForEach(catalogs) { reference in
                    Button {
                        Task { await browser.descend(to: reference.url, title: reference.title) }
                    } label: {
                        SettingsLinkRow(
                            title: reference.title,
                            subtitle: reference.summary,
                            systemImage: "square.stack.3d.up"
                        )
                    }
                    .buttonStyle(PressableStyle())
                }
                ForEach(webCatalogs) { catalog in
                    webCatalogRow(catalog)
                }
            }
        }
    }

    private func webCatalogRow(_ catalog: OPDSWebCatalog) -> some View {
        Button {
            openURL(catalog.url)
        } label: {
            SettingsLinkRow(
                title: catalog.title,
                subtitle: catalog.summary ?? catalog.url.host,
                systemImage: "safari"
            )
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Opens outside Enve in your browser")
    }

    @ViewBuilder
    private var facetsCard: some View {
        let groups = browser.page?.facetGroups ?? []
        if !groups.isEmpty {
            SourcesCard {
                Overline("Filter")
                ForEach(groups) { group in
                    if !group.title.isEmpty {
                        Text(group.title)
                            .font(.hearthUI(11, weight: .semibold))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    ForEach(group.facets) { facet in
                        SettingsChoiceRow(
                            title: facet.title,
                            caption: facet.count.map { "\($0) publications" },
                            isSelected: facet.isActive
                        ) {
                            Task { await browser.descend(to: facet.url, title: facet.title) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var groupsSection: some View {
        ForEach(browser.page?.groups ?? []) { group in
            SourcesCard {
                HStack {
                    Overline(group.title.isEmpty ? "Group" : group.title)
                    Spacer()
                    if let url = group.url {
                        Button("See all") {
                            Task { await browser.descend(to: url, title: group.title) }
                        }
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.ember)
                    }
                }
                ForEach(group.navigation) { entry in
                    Button {
                        Task { await browser.descend(to: entry.url, title: entry.title) }
                    } label: {
                        SettingsLinkRow(title: entry.title, systemImage: "folder")
                    }
                    .buttonStyle(PressableStyle())
                }
                ForEach(group.webCatalogs) { catalog in
                    webCatalogRow(catalog)
                }
                ForEach(group.publications) { entry in
                    publicationRow(entry)
                }
            }
        }
    }

    // MARK: Publications

    private var publicationsCard: some View {
        SourcesCard {
            HStack {
                Overline("Publications")
                Spacer()
                if !browser.importableBooks.isEmpty {
                    Button(browser.isEverythingSelected ? "Choose some" : "All") {
                        if browser.isEverythingSelected {
                            browser.clearSelection()
                        } else {
                            browser.selectEverything()
                        }
                    }
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.ember)
                }
            }

            if browser.isLoading && browser.page == nil {
                HStack(spacing: 10) {
                    ProgressView().tint(hearth.ember)
                    Text("Reading the catalogue…")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else if browser.page?.publications.isEmpty != false {
                Text("No publications on this page.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                ForEach(browser.page?.publications ?? []) { entry in
                    publicationRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func publicationRow(_ entry: OPDSPublicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let book = entry.book {
                    Button {
                        browser.toggleSelection(of: book.id)
                    } label: {
                        Image(systemName: browser.selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(browser.selection.contains(book.id) ? hearth.ember : hearth.textTertiary)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Select \(entry.title)")
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(hearth.textTertiary)
                        .accessibilityHidden(true)
                }

                CachedAsyncCoverImage(
                    url: entry.thumbnailURL ?? entry.coverURL,
                    fallbackColor: "Blue",
                    headers: browser.imageHeaders(for: entry.thumbnailURL ?? entry.coverURL)
                )
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .lineLimit(3)
                    if let author = entry.authorText {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(2)
                    }
                    if let caption = metadataCaption(entry) {
                        Text(caption)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                            .lineLimit(2)
                    }
                    if let reason = entry.unavailableReason {
                        Text(reason)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.statusWarn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    itemStateText(entry)
                }
                Spacer(minLength: 0)
            }

            actions(for: entry)
        }
        .padding(.vertical, 2)
    }

    private func metadataCaption(_ entry: OPDSPublicationEntry) -> String? {
        var parts: [String] = []
        if let series = entry.seriesInfo?.name {
            parts.append(entry.seriesInfo?.sequence.map { "\(series) #\($0)" } ?? series)
        }
        if let duration = entry.duration, duration > 0 {
            parts.append(HearthFormat.clock(duration))
        }
        if !entry.narrators.isEmpty {
            parts.append("Read by \(entry.narrators.joined(separator: ", "))")
        }
        if let format = entry.fulfillable?.format.ebookFormat?.displayName {
            parts.append(format)
        }
        if let year = entry.publishedYear { parts.append(String(year)) }
        if let language = entry.languages.first, !language.isEmpty { parts.append(language.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func itemStateText(_ entry: OPDSPublicationEntry) -> some View {
        switch browser.state(of: entry) {
        case .idle:
            EmptyView()
        case .downloading(let progress):
            Text("Downloading… \(Int(progress * 100))%")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.statusOK)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.statusWarn)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func actions(for entry: OPDSPublicationEntry) -> some View {
        let downloadable = entry.fulfillable.flatMap { $0.format.mediaType == .ebook ? $0 : nil }
        let sample = entry.sample
        let transactions = entry.transactions

        if downloadable != nil || sample != nil || !transactions.isEmpty {
            HStack(spacing: 8) {
                if let downloadable {
                    acquisitionButton(entry, downloadable, isProminent: true)
                }
                if let sample, sample.url != downloadable?.url {
                    acquisitionButton(entry, sample, isProminent: false)
                }
                ForEach(Array(transactions.enumerated()), id: \.offset) { _, transaction in
                    acquisitionButton(entry, transaction, isProminent: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 76)
        } else if let reason = entry.unavailableSampleReason {
            Text(reason)
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 76)
        }
    }

    @ViewBuilder
    private func acquisitionButton(
        _ entry: OPDSPublicationEntry,
        _ acquisition: OPDSAcquisition,
        isProminent: Bool
    ) -> some View {
        Button {
            if acquisition.kind.deliversTheFile || acquisition.kind == .preview {
                Task { await browser.download(entry, using: acquisition) }
            } else {
                openURL(acquisition.url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(acquisition.kind.actionName)
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(isProminent ? hearth.ember : hearth.text)
                if let terms = OPDSAcquisitionSelector.termsText(for: acquisition) {
                    Text(terms)
                        .font(.hearthUI(10))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(isProminent ? hearth.ember.opacity(0.14) : hearth.bg)
            }
            .overlay {
                Capsule().stroke(hearth.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Pagination and import

    @ViewBuilder
    private var paginationCard: some View {
        if let pagination = browser.page?.pagination, pagination.hasPages {
            SourcesCard {
                HStack(spacing: 12) {
                    if let previous = pagination.previous {
                        Button {
                            Task { await browser.descend(to: previous, title: "Previous page") }
                        } label: {
                            Label("Previous", systemImage: "chevron.left")
                                .font(.hearthCaption.weight(.medium))
                                .foregroundStyle(hearth.ember)
                        }
                        .buttonStyle(PressableStyle())
                    }
                    Spacer(minLength: 0)
                    if let caption = pageCaption(pagination) {
                        Text(caption)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if let next = pagination.next {
                        Button {
                            Task { await browser.descend(to: next, title: "Next page") }
                        } label: {
                            Label("Next", systemImage: "chevron.right")
                                .font(.hearthCaption.weight(.medium))
                                .foregroundStyle(hearth.ember)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    private func pageCaption(_ pagination: OPDSPagination) -> String? {
        var parts: [String] = []
        if let page = pagination.currentPage {
            if let items = pagination.numberOfItems, let perPage = pagination.itemsPerPage, perPage > 0 {
                parts.append("Page \(page) of \((items + perPage - 1) / perPage)")
            } else {
                parts.append("Page \(page)")
            }
        }
        if let total = pagination.numberOfItems { parts.append("\(total) publications") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var importBar: some View {
        if !browser.importableBooks.isEmpty {
            SourcesField(
                label: "Collection name",
                text: $collectionName,
                placeholder: selectedConnection?.name ?? "Collection"
            )
            EmberButton(
                title: importer.isRunning ? "Importing…" : "Import \(browser.selectedBooks.count)",
                systemImage: importer.isRunning ? nil : "arrow.down.circle",
                tint: nil
            ) {
                guard let connection = selectedConnection else { return }
                let books = browser.selectedBooks
                Task {
                    await importer.importBooks(
                        books,
                        from: connection,
                        collectionName: collectionName.isEmpty ? connection.name : collectionName
                    )
                }
            }
            .disabled(importer.isRunning || browser.selectedBooks.isEmpty)
            .opacity(importer.isRunning || browser.selectedBooks.isEmpty ? 0.5 : 1)
        }
    }

    private func openSelectedConnection() async {
        guard let connection = selectedConnection else { return }
        if collectionName.isEmpty { collectionName = connection.name }
        await browser.open(connection)
        await browser.loadSignInChallenge()
    }
}
