import Foundation

@MainActor
final class LibrarianConversationStore {
    static let shared = LibrarianConversationStore()

    private static let prefix = "enveLibrarian.messages."
    private let userDefaults = UserDefaults.standard

    private init() {}

    func loadMessages(bookStableId: String) -> [LibrarianMessage] {
        guard let data = userDefaults.data(forKey: Self.prefix + bookStableId),
            let messages = try? JSONDecoder().decode([LibrarianMessage].self, from: data)
        else {
            return []
        }
        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    func saveMessages(_ messages: [LibrarianMessage], bookStableId: String) {
        let trimmed = Array(messages.suffix(80))
        if let data = try? JSONEncoder().encode(trimmed) {
            userDefaults.set(data, forKey: Self.prefix + bookStableId)
        }
    }

    func clear(bookStableId: String) {
        userDefaults.removeObject(forKey: Self.prefix + bookStableId)
    }
}
