import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileReaderPreferenceTests {
    @Test func appearanceCapturesItsProfileDefaults() throws {
        let firstName = "reader-profile-\(UUID().uuidString)"
        let secondName = "reader-profile-\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstName))
        let second = try #require(UserDefaults(suiteName: secondName))
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
        var original = ClassicReaderAppearance()
        original.fontSize = 1.4
        original.persist(defaults: first)
        var other = ClassicReaderAppearance()
        other.fontSize = 1.8
        other.persist(defaults: second)
        let controller = ReaderAppearanceController(appearance: .load(defaults: first),
            persist: { $0.persist(defaults: first) })
        controller.appearance.fontSize = 1.6
        controller.flushPendingUpdate()
        #expect(ClassicReaderAppearance.load(defaults: first).fontSize == 1.6)
        #expect(ClassicReaderAppearance.load(defaults: second).fontSize == 1.8)
    }
}
