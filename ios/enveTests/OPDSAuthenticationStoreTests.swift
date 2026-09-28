import Foundation
import Testing

@testable import enve

/// A token store that never touches the Keychain, so the store's retention and expiry rules can be
/// exercised in a test process.
@MainActor
final class InMemoryOPDSTokenStore: OPDSTokenStoring {
    private var tokens: [UUID: OAuthToken] = [:]

    func token(forConnectionId connectionId: UUID) -> OAuthToken? { tokens[connectionId] }

    func setToken(_ token: OAuthToken?, forConnectionId connectionId: UUID) {
        tokens[connectionId] = token
    }
}

@MainActor
struct OPDSAuthenticationStoreTests {
    private static let connection = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    private static let other = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!

    private func makeStore(_ suite: String = UUID().uuidString) -> (OPDSAuthenticationStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (OPDSAuthenticationStore(defaults: defaults, tokens: InMemoryOPDSTokenStore()), defaults)
    }

    private func token(expiresIn: Int?, issuedAt: Date = Date()) -> OAuthToken {
        OAuthToken(
            accessToken: "lab-access",
            refreshToken: "lab-refresh",
            expiresIn: expiresIn,
            tokenType: "Bearer",
            scope: nil,
            issuedAt: issuedAt
        )
    }

    @Test func aLiveTokenBecomesAnAuthorizationHeader() {
        let (store, _) = makeStore()
        store.setToken(token(expiresIn: 3600), for: Self.connection)

        #expect(store.authorizationHeaderValue(for: Self.connection) == "Bearer lab-access")
    }

    /// Sending a token Enve already knows is stale turns a refusal the reader could act on into one they
    /// cannot: the refresh has to run first.
    @Test func anExpiredTokenIsWithheld() {
        let (store, _) = makeStore()
        store.setToken(token(expiresIn: 60, issuedAt: Date(timeIntervalSinceNow: -120)), for: Self.connection)

        #expect(store.authorizationHeaderValue(for: Self.connection) == nil)
    }

    @Test func aTokenWithNoStatedLifetimeIsStillSent() {
        let (store, _) = makeStore()
        store.setToken(token(expiresIn: nil), for: Self.connection)

        #expect(store.authorizationHeaderValue(for: Self.connection) == "Bearer lab-access")
    }

    @Test func aSessionSurvivesARelaunch() {
        let suite = UUID().uuidString
        let (store, defaults) = makeStore(suite)
        store.setSession(
            OPDSAuthenticationStore.Session(
                flowType: "http://opds-spec.org/auth/oauth/password",
                refreshURL: URL(string: "https://catalog.example.invalid/token"),
                accountLabel: "reader"
            ),
            for: Self.connection
        )

        let reopened = OPDSAuthenticationStore(defaults: defaults, tokens: InMemoryOPDSTokenStore())

        #expect(reopened.session(for: Self.connection)?.accountLabel == "reader")
        #expect(
            reopened.session(for: Self.connection)?.refreshURL?.absoluteString
                == "https://catalog.example.invalid/token"
        )
    }

    @Test func aConnectionThatGoesAwayTakesItsSignInWithIt() {
        let (store, _) = makeStore()
        store.setSession(OPDSAuthenticationStore.Session(flowType: "basic"), for: Self.connection)
        store.setSession(OPDSAuthenticationStore.Session(flowType: "basic"), for: Self.other)
        store.setToken(token(expiresIn: 3600), for: Self.connection)

        store.retainConnections([Self.other])

        #expect(store.session(for: Self.connection) == nil)
        #expect(store.token(for: Self.connection) == nil)
        #expect(store.session(for: Self.other) != nil)
    }

    @Test func signingOutForgetsTheTokenAndTheChallenge() {
        let (store, _) = makeStore()
        store.setSession(OPDSAuthenticationStore.Session(flowType: "basic"), for: Self.connection)
        store.setToken(token(expiresIn: 3600), for: Self.connection)
        store.recordChallenge(
            OPDSAuthenticationDocument.decode(Data(OPDSAuthenticationFixtures.basic.utf8), baseURL: Self.base),
            for: Self.connection
        )

        store.signOut(connectionId: Self.connection)

        #expect(store.session(for: Self.connection) == nil)
        #expect(store.token(for: Self.connection) == nil)
        #expect(store.challenge(for: Self.connection) == nil)
    }

    private static let base = URL(string: "https://catalog.example.invalid/opds/root.json")!
}
