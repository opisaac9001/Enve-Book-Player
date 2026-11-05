import Testing

@testable import enve

struct StorytellerAuthenticationTests {
    @Test func unauthorizedResponseRequiresReauthentication() {
        #expect(StorytellerProvider.responseRequiresReauthentication(statusCode: 401))
    }

    @Test func forbiddenResponseRemainsAPermissionFailure() {
        #expect(!StorytellerProvider.responseRequiresReauthentication(statusCode: 403))
    }
}
