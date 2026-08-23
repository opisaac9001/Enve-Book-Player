import Foundation
import Observation

@MainActor
@Observable
final class StoryAlignService {
    static let shared = StoryAlignService()
    private init() {}

    func syncReadAloudLibraryOnLaunch() async {}

    func syncReadAloudLibrary() {}

    func cleanupOrphanedCaches(allBooks: [Book]) {}

    func deleteConversions(involving book: Book) {}

    func deleteAllConversions() {}
}
