import Foundation
import Logging

/// Inject provider resolution so navigation tests do not depend on the global registry.
@MainActor
protocol OPDSProviderMaking {
    func makeLibraryProvider(for connection: ServerConnection) -> LibraryProvider?
}

extension PluginRegistry: OPDSProviderMaking {}

/// Preserves catalog navigation, groups, facets, and acquisitions that library import cannot represent.
@MainActor
@Observable
final class OPDSCatalogBrowser {
    struct Step: Identifiable, Hashable {
        let title: String
        let url: URL

        var id: String { url.absoluteString }
    }

    enum ItemState: Equatable {
        case idle
        case downloading(progress: Double)
        case downloaded
        case failed(message: String)
    }

    private(set) var page: OPDSCatalogPage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Where the reader is, root first. The last entry is the page on screen.
    private(set) var trail: [Step] = []
    /// Carry root search metadata into subfeeds that omit it.
    private(set) var search: OPDSSearchDescriptor?
    private(set) var isSearchResult = false
    private(set) var itemStates: [String: ItemState] = [:]
    /// Reconcile selection with each loaded page so bulk import only includes visible publications.
    private(set) var selection: Set<String> = []
    /// The sign-in the server asked for, when it refused the credentials the connection holds.
    private(set) var signInChallenge: OPDSAuthenticationDocument?

    /// Update the trail only after a successful load.
    private enum TrailPlacement {
        case root
        case descend
        case replaceCurrent
        case ascend
    }

    private var connection: ServerConnection?
    private var provider: OPDSProvider?
    private let providers: any OPDSProviderMaking
    private let authenticationStore: OPDSAuthenticationStore
    private let connections: (any ProviderConnectionEditing)?
    private let adoptSample: (URL) async throws -> Void

    init(
        providers: any OPDSProviderMaking = PluginRegistry.shared,
        authenticationStore: OPDSAuthenticationStore = .shared,
        connections: (any ProviderConnectionEditing)? = AppState.shared.providerConnections,
        adoptSample: @escaping (URL) async throws -> Void = OPDSCatalogBrowser.importIntoLocalLibrary
    ) {
        self.providers = providers
        self.authenticationStore = authenticationStore
        self.connections = connections
        self.adoptSample = adoptSample
    }

    /// Store samples as local books so catalog reconciliation cannot remove them.
    private static func importIntoLocalLibrary(_ url: URL) async throws {
        _ = try await EnveEngine.shared.sources.importFiles(urls: [url], mode: .splitSelectedBooks)
    }

    var activeConnection: ServerConnection? { connection }

    var canGoBack: Bool { trail.count > 1 }

    var title: String { trail.last?.title ?? connection?.name ?? "OPDS" }

    /// Every publication on the page, groups included, in the order the catalog wrote them.
    var publications: [OPDSPublicationEntry] { page?.allPublications ?? [] }

    var importableBooks: [Book] { publications.compactMap(\.book) }

    var selectedBooks: [Book] { importableBooks.filter { selection.contains($0.id) } }

    var isEverythingSelected: Bool {
        !importableBooks.isEmpty && selection.count == importableBooks.count
    }

    func toggleSelection(of bookId: String) {
        if selection.contains(bookId) {
            selection.remove(bookId)
        } else {
            selection.insert(bookId)
        }
    }

    func selectEverything() { selection = Set(importableBooks.map(\.id)) }

    func clearSelection() { selection = [] }

    func state(of entry: OPDSPublicationEntry) -> ItemState { itemStates[entry.id] ?? .idle }

    /// The image cache uses a separate session; supply credentials only for feed-origin covers.
    func imageHeaders(for url: URL?) -> [String: String] {
        guard let url, let provider else { return [:] }
        return provider.credentialHeaders(for: url)
    }

    // MARK: Navigation

    func open(_ connection: ServerConnection) async {
        guard self.connection?.id != connection.id else { return }
        await adopt(connection)
    }

    /// Rebuild the provider after sign-in to pick up changed connection credentials.
    func reloadAfterSignIn(with connection: ServerConnection) async {
        await adopt(connection)
    }

    func descend(to url: URL, title: String) async {
        await load(url: url, title: title, placement: .descend)
    }

    func goBack() async {
        guard canGoBack else { return }
        let parent = trail[trail.count - 2]
        await load(url: parent.url, title: parent.title, placement: .ascend)
    }

    /// Reload the root when failed initial loading left the trail empty.
    func reload() async {
        guard let step = trail.last else {
            await load(url: provider?.feedURL(), title: connection?.name ?? "OPDS", placement: .root)
            return
        }
        await load(url: step.url, title: step.title, placement: .replaceCurrent)
    }

    private func adopt(_ connection: ServerConnection) async {
        self.connection = connection
        provider = providers.makeLibraryProvider(for: connection) as? OPDSProvider
        trail = []
        search = nil
        isSearchResult = false
        itemStates = [:]
        selection = []
        signInChallenge = nil
        await load(url: provider?.feedURL(), title: connection.name, placement: .root)
    }

    // MARK: Search

    var canSearch: Bool { search != nil }

    func search(for terms: String) async {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let provider, let descriptor = search else { return }

        isLoading = true
        defer { isLoading = false }

        guard let resolved = await provider.resolveSearch(descriptor) else {
            errorMessage = "This catalogue's search description could not be read."
            return
        }
        search = resolved
        guard let url = resolved.url(forTerms: trimmed) else {
            errorMessage = "This catalogue's search template could not be filled in."
            return
        }

        await load(url: url, title: "Results for “\(trimmed)”", placement: .descend, isSearch: true)
    }

    func clearSearch() async {
        guard isSearchResult else { return }
        await goBack()
    }

    // MARK: Acquisitions

    func download(_ entry: OPDSPublicationEntry, using acquisition: OPDSAcquisition) async {
        guard let provider, let connection else { return }
        // Surface unsupported acquisitions as errors instead of silently ignoring the action.
        if let reason = OPDSAcquisitionSelector.undeliverableReason(for: acquisition) {
            itemStates[entry.id] = .failed(message: reason)
            return
        }

        // A sample must not overwrite the full publication selected during import.
        let book =
            entry.book.flatMap { $0.partKey == acquisition.url.absoluteString ? $0 : nil }
            ?? self.book(for: entry, acquisition: acquisition, connection: connection)

        itemStates[entry.id] = .downloading(progress: 0)
        do {
            let identifier = entry.id
            let file = try await provider.downloadEbook(for: book) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.itemStates[identifier] = .downloading(progress: progress)
                }
            }
            if acquisition.kind == .preview { try await adoptSample(file) }
            itemStates[entry.id] = .downloaded
        } catch {
            itemStates[entry.id] = .failed(message: error.localizedDescription)
            AppLogger.network.warning("[OPDS] Acquisition failed: \(error.localizedDescription)")
        }
    }

    /// Give samples a separate identity to preserve any downloaded full book.
    private func book(
        for entry: OPDSPublicationEntry,
        acquisition: OPDSAcquisition,
        connection: ServerConnection
    ) -> Book {
        Book(
            id: "\(entry.identity)#\(acquisition.kind == .preview ? "sample" : "acquisition")",
            title: acquisition.kind == .preview ? "\(entry.title) (sample)" : entry.title,
            author: entry.authorText,
            coverURL: entry.coverURL,
            partKey: acquisition.url.absoluteString,
            mediaType: .ebook,
            ebookFormat: acquisition.format.ebookFormat?.rawValue,
            description: entry.summary,
            lastUpdate: entry.modified ?? .distantPast,
            libraryId: OPDSProvider.rootLibraryId,
            providerId: connection.id,
            source: .opds
        )
    }

    // MARK: Authentication

    /// What the reader signed in as, and `nil` when no flow has been adopted for this connection.
    var signedInAccount: String? {
        guard let connection, authenticationStore.isSignedIn(connectionId: connection.id) else { return nil }
        return authenticationStore.session(for: connection.id)?.accountLabel ?? "Signed in"
    }

    /// Clear OAuth and Basic credentials, then reload to rediscover authentication requirements.
    func signOut() async {
        guard let connection else { return }
        let flow = authenticationStore.session(for: connection.id)?.flowType ?? ""
        authenticationStore.signOut(connectionId: connection.id)

        var cleared = connection
        if OPDSAuthenticationFlow.Kind(type: flow) == .httpCredentials,
            let connections,
            let index = connections.connections.firstIndex(where: { $0.id == connection.id })
        {
            cleared.username = nil
            cleared.password = nil
            cleared.isConnected = false
            connections.connections[index] = cleared
        }

        await adopt(cleared)
        await loadSignInChallenge()
    }

    private func refreshSignInChallenge() {
        guard let connection else { return }
        signInChallenge = authenticationStore.challenge(for: connection.id)
    }

    /// Offer advertised sign-in without waiting for a 401.
    func loadSignInChallenge() async {
        guard let connection, let provider else { return }
        if let recorded = authenticationStore.challenge(for: connection.id) {
            signInChallenge = recorded
            return
        }
        guard let url = authenticationStore.session(for: connection.id)?.documentURL,
            let document = await provider.fetchAuthenticationDocument(at: url)
        else { return }
        authenticationStore.recordChallenge(document, for: connection.id)
        signInChallenge = document
    }

    // MARK: Loading

    private func load(
        url: URL?,
        title: String,
        placement: TrailPlacement,
        isSearch: Bool = false
    ) async {
        guard let provider, let url else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await provider.fetchCatalogPage(at: url)
            page = loaded
            isSearchResult = isSearch
            itemStates = [:]
            selection.formIntersection(importableBooks.map(\.id))
            if let discovered = loaded.search { search = discovered }
            place(Step(title: loaded.title ?? title, url: url), placement)
            signInChallenge = nil
        } catch {
            // Keep the current page on failure; only a failed root load has no previous page.
            if placement == .root {
                page = nil
                trail = []
                selection = []
            }
            errorMessage = error.localizedDescription
            refreshSignInChallenge()
        }
    }

    private func place(_ step: Step, _ placement: TrailPlacement) {
        switch placement {
        case .root:
            trail = [step]
        case .descend:
            trail.append(step)
        case .replaceCurrent:
            if trail.isEmpty { trail = [step] } else { trail[trail.count - 1] = step }
        case .ascend:
            trail.removeLast()
            trail[trail.count - 1] = step
        }
    }
}
