import Foundation
import Testing

@testable import enve

struct HardcoverResponseDecodingTests {
    @Test func readingMutationPreservesServerIdentity() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let inserted = try decoder.decode(InsertReadSessionResponse.self, from: Data(#"{"insert_user_book_read":{"error":null,"user_book_read":{"id":71,"started_at":"2026-09-04","progress_pages":32}}}"#.utf8))
        #expect(try inserted.createdReadId() == 71)
        #expect(inserted.insertUserBookRead?.userBookRead?.progressPages == 32)

        let updated = try decoder.decode(UpdateReadProgressResponse.self, from: Data(#"{"update_user_book_read":{"error":null,"user_book_read":{"id":71,"progress_pages":50}}}"#.utf8))
        try updated.validate()
        #expect(updated.updateUserBookRead?.userBookRead?.progressPages == 50)
    }

    @Test func nestedMutationErrorsCannotReportSuccess() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let inserted = try decoder.decode(InsertReadSessionResponse.self, from: Data(#"{"insert_user_book_read":{"error":"Rejected","user_book_read":null}}"#.utf8))
        #expect(throws: HardcoverError.self) { try inserted.createdReadId() }
        let updated = try decoder.decode(UpdateReadProgressResponse.self, from: Data(#"{"update_user_book_read":{"error":"Rejected","user_book_read":null}}"#.utf8))
        #expect(throws: HardcoverError.self) { try updated.validate() }
        let rated = try decoder.decode(GenericUpdateResponse.self, from: Data(#"{"update_user_book":{"error":"Rejected"}}"#.utf8))
        #expect(throws: HardcoverError.self) { try rated.validate() }
    }

    @Test func missingMutationResultsAreFailures() throws {
        let decoder = JSONDecoder()
        let inserted = try decoder.decode(InsertReadSessionResponse.self, from: Data("{}".utf8))
        #expect(throws: HardcoverError.self) { try inserted.createdReadId() }
        let updated = try decoder.decode(UpdateReadProgressResponse.self, from: Data("{}".utf8))
        #expect(throws: HardcoverError.self) { try updated.validate() }
        let rated = try decoder.decode(GenericUpdateResponse.self, from: Data("{}".utf8))
        #expect(throws: HardcoverError.self) { try rated.validate() }
    }
}
