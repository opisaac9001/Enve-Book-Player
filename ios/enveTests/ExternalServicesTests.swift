import Foundation
import Testing
import os

@testable import enve

@Suite(.serialized) @MainActor
struct ExternalServicesTests {
    @Test func everyServiceIsAllowedByDefault() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let policy = ExternalServicesPolicy(defaults: defaults)
        let store = ExternalServicesStore(policy: policy)

        for service in ExternalService.allCases {
            #expect(policy.isAllowed(service))
            #expect(store.isEnabled(service))
        }
        #expect(store.disabledServices.isEmpty)
    }

    @Test func turningAServiceOffPersistsUntilTurnedBackOn() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        ExternalServicesStore(policy: ExternalServicesPolicy(defaults: defaults)).setEnabled(false, for: .googleBooks)

        let relaunched = ExternalServicesStore(policy: ExternalServicesPolicy(defaults: defaults))
        #expect(relaunched.disabledServices == [.googleBooks])
        #expect(!ExternalServicesPolicy(defaults: defaults).isAllowed(.googleBooks))

        relaunched.setEnabled(true, for: .googleBooks)
        #expect(ExternalServicesPolicy(defaults: defaults).isAllowed(.googleBooks))
        #expect(ExternalServicesStore(policy: ExternalServicesPolicy(defaults: defaults)).disabledServices.isEmpty)
    }

    @Test func disabledCatalogClientsNeverReachTheNetwork() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ExternalServicesPolicy(defaults: defaults)
        ExternalService.allCases.forEach { policy.setAllowed(false, for: $0) }
        ExternalServicesFixture.install { _ in ExternalServicesFixture.Reply(body: "{}") }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }

        let audible = AudibleService(session: session, policy: policy)
        let itunes = iTunesService(session: session, policy: policy)
        let openLibrary = OpenLibraryService(session: session, policy: policy)
        let googleBooks = GoogleBooksService(session: session, policy: policy)
        let comicVine = ComicVineService(session: session, policy: policy)
        let podcasts = iTunesPodcastProvider(session: session, policy: policy)
        let discover = DiscoverService(audible: audible, policy: policy)

        await expectBlocked(.audible) { _ = try await audible.simpleSearch(query: "Dune") }
        await expectBlocked(.audible) { _ = try await audible.search(query: "Dune") }
        await expectBlocked(.audible) { _ = try await audible.getSearchResultByASIN(asin: "B002V1BPOO") }
        await expectBlocked(.audible) { _ = try await audible.getProductDetails(asin: "B002V1BPOO") }
        await expectBlocked(.audible) { _ = try await discover.fetchTrending() }
        await expectBlocked(.audible) { _ = try await discover.fetchBestsellers() }
        await expectBlocked(.audible) { _ = try await discover.fetchNewReleases() }
        await expectBlocked(.appleCatalog) { _ = try await itunes.search(query: "Dune") }
        await expectBlocked(.appleCatalog) { _ = try await itunes.lookup(id: 42) }
        await expectBlocked(.appleCatalog) { _ = try await podcasts.search(term: "history") }
        await expectBlocked(.appleCatalog) { _ = try await podcasts.lookup(collectionId: "42") }
        await expectBlocked(.appleCatalog) { _ = try await podcasts.topPodcasts(genreId: nil) }
        await expectBlocked(.googleBooks) { _ = try await googleBooks.search(query: "Dune", author: nil, isbn: "9780441013593") }
        await expectBlocked(.openLibrary) { _ = try await openLibrary.search(query: "Dune") }
        await expectBlocked(.openLibrary) { _ = try await openLibrary.getWorkDescription(workKey: "/works/OL893415W") }
        await expectBlocked(.comicVine) { _ = try await comicVine.search(query: "Saga") }

        #expect(ExternalServicesFixture.requestedPaths.isEmpty)
    }

    @Test func blockedLookupIsDistinctFromAnEmptyResult() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ExternalServicesPolicy(defaults: defaults)
        ExternalServicesFixture.install { request in
            request.url?.host == "itunes.apple.com"
                ? ExternalServicesFixture.Reply(body: #"{"resultCount":0,"results":[]}"#)
                : ExternalServicesFixture.Reply(body: #"{"numFound":0,"docs":[]}"#)
        }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let openLibrary = OpenLibraryService(session: session, policy: policy)
        let itunes = iTunesService(session: session, policy: policy)

        #expect(try await openLibrary.search(query: "No such book").isEmpty)
        #expect(try await itunes.search(query: "No such book").isEmpty)
        #expect(ExternalServicesFixture.requestedPaths.count == 2)

        policy.setAllowed(false, for: .openLibrary)
        do {
            _ = try await openLibrary.search(query: "No such book")
            Issue.record("A turned-off service must report that it is off, not an empty result.")
        } catch let error as ExternalServiceDisabledError {
            #expect(error.service == .openLibrary)
            #expect(error.localizedDescription == "Open Library is turned off in Settings › External services.")
            #expect(!error.localizedDescription.contains("http"))
        }
        #expect(try await itunes.search(query: "No such book").isEmpty)
        #expect(ExternalServicesFixture.requestedPaths.count == 3)
    }

    @Test func turningOffDuringAChartRequestSkipsTheFollowUpLookup() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ExternalServicesPolicy(defaults: defaults)
        ExternalServicesFixture.install { request in
            policy.setAllowed(false, for: .appleCatalog)
            guard request.url?.path.contains("toppodcasts") == true else {
                return ExternalServicesFixture.Reply(body: #"{"resultCount":0,"results":[]}"#)
            }
            return ExternalServicesFixture.Reply(body: #"{"feed":{"entry":[{"id":{"attributes":{"im:id":"42"}}}]}}"#)
        }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let podcasts = iTunesPodcastProvider(session: session, policy: policy)

        await expectBlocked(.appleCatalog) { _ = try await podcasts.topPodcasts(genreId: nil) }

        let paths = ExternalServicesFixture.requestedPaths
        #expect(paths.count == 1)
        #expect(paths.first?.contains("toppodcasts") == true)
    }

    @Test func discoverStopsQueryingOnceAudibleIsTurnedOff() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ExternalServicesPolicy(defaults: defaults)
        ExternalServicesFixture.install { _ in
            policy.setAllowed(false, for: .audible)
            return ExternalServicesFixture.Reply(body: #"{"products":[]}"#)
        }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let discover = DiscoverService(audible: AudibleService(session: session, policy: policy), policy: policy)

        await expectBlocked(.audible) { _ = try await discover.fetchTrending() }

        #expect(ExternalServicesFixture.requestedPaths.count == 1)
    }

    @Test func turningOffDuringGoogleFailurePreventsTheDelayedRetry() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ExternalServicesPolicy(defaults: defaults)
        ExternalServicesFixture.install { _ in
            policy.setAllowed(false, for: .googleBooks)
            return ExternalServicesFixture.Reply(status: 503, body: "{}")
        }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let google = GoogleBooksService(session: session, policy: policy)

        await expectBlocked(.googleBooks) { _ = try await google.search(query: "Dune", author: nil, isbn: nil) }

        #expect(ExternalServicesFixture.requestedPaths.count == 1)
    }

    @Test func userServersAreNotTreatedAsExternalCatalogs() {
        #expect(MatchesSearchModel.Source.audiobookshelf.externalService == nil)
        #expect(MatchesSearchModel.Source.enveSearch.externalService == .audible)
        #expect(MatchesSearchModel.Source.iTunes.externalService == .appleCatalog)
        #expect(MatchesSearchModel.Source.googleBooks.externalService == .googleBooks)
        #expect(MatchesSearchModel.Source.openLibrary.externalService == .openLibrary)
        #expect(MatchesSearchModel.Source.comicVine.externalService == .comicVine)
    }

    private func expectBlocked(
        _ service: ExternalService,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("\(service.rawValue) ran while turned off.", sourceLocation: sourceLocation)
        } catch let error as ExternalServiceDisabledError {
            #expect(error.service == service, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected the turned-off error, got \(error).", sourceLocation: sourceLocation)
        }
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "ExternalServicesTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalServicesFixture.self]
        return URLSession(configuration: configuration)
    }
}

nonisolated private final class ExternalServicesFixture: URLProtocol, @unchecked Sendable {
    nonisolated struct Reply: Sendable {
        var status = 200
        var body: String
    }

    nonisolated private struct State: Sendable {
        var handler: (@Sendable (URLRequest) -> Reply)?
        var paths: [String] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        state.withLock { $0 = State(handler: handler) }
    }

    static var requestedPaths: [String] {
        state.withLock { $0.paths }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let handler = Self.state.withLock { state -> (@Sendable (URLRequest) -> Reply)? in
            state.paths.append(request.url?.path ?? "")
            return state.handler
        }
        guard let url = request.url, let reply = handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
