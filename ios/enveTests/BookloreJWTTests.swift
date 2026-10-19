import Foundation
import Testing

@testable import enve

struct BookloreJWTTests {
    @Test func refreshActivationUsesTheNotBeforeBoundary() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["nbf": 120, "exp": 600])
        let token = "e30." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".fixture"
        let jwt = try #require(BookloreJWT(token))
        #expect(!jwt.isActive(at: Date(timeIntervalSince1970: 119)))
        #expect(jwt.isActive(at: Date(timeIntervalSince1970: 120)))
        #expect(jwt.isActive(at: Date(timeIntervalSince1970: 121)))
        #expect(BookloreJWT("e30.e30.fixture")?.isActive(at: .distantPast) == true)
    }
}
