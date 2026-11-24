#if os(iOS)
import AppIntents
import Combine
import CoreSpotlight
import Foundation
import Logging
import UIKit
import UniformTypeIdentifiers

@MainActor
final class EbookSpotlightIndex {
    static let shared = EbookSpotlightIndex()
    static let domain = "com.enve.ebooks.owner"
    private let index = CSSearchableIndex(name: "EnveEbooks", protectionClass: .complete)
    private var subscriptions = Set<AnyCancellable>()
    private var operation: Task<Void, Never>?
    private var lastIndexed: [SystemEbook]?
    private var lastIndexedAt = Date.distantPast
    private var removalGeneration = 0
    private var removalBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        NotificationCenter.default.publisher(for: .bookStoreDidChange)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .preferencesDidChange)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    func refresh() {
        guard let session = EbookSystemService.permittedSession, session.allowsSystemAccess else {
            revoke()
            return
        }
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let previous = operation
        previous?.cancel()
        operation = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            let books = await session.ebookSystem.spotlightBooks().sorted { $0.id < $1.id }
            guard !Task.isCancelled, EbookSystemService.permittedSession === session, session.allowsSystemAccess else { return }
            guard UIApplication.shared.isProtectedDataAvailable,
                books != lastIndexed || Date().timeIntervalSince(lastIndexedAt) >= 24 * 60 * 60 else { return }
            EnveAppShortcuts.updateAppShortcutParameters()
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                lastIndexed = nil
                guard !Task.isCancelled, EbookSystemService.permittedSession === session, session.allowsSystemAccess else { return }
                try await index.indexSearchableItems(books.map(Self.item))
                if !Task.isCancelled {
                    lastIndexed = books
                    lastIndexedAt = Date()
                }
            } catch {
                AppLogger.general.error("Ebook Spotlight index refresh failed")
            }
        }
    }

    func revoke() {
        lastIndexed = nil
        removalGeneration += 1
        let generation = removalGeneration
        if removalBackgroundTask == .invalid {
            removalBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Remove ebook search results") { [weak self] in
                self?.endRemovalBackgroundTask()
            }
        }
        let previous = operation
        previous?.cancel()
        // Serialize removal after an in-flight donation so a profile switch cannot restore stale metadata.
        operation = Task {
            defer { if generation == removalGeneration { endRemovalBackgroundTask() } }
            await previous?.value
            EnveAppShortcuts.updateAppShortcutParameters()
            do { try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) }
            catch { AppLogger.general.error("Ebook Spotlight index removal failed") }
        }
    }

    private func endRemovalBackgroundTask() {
        guard removalBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(removalBackgroundTask)
        removalBackgroundTask = .invalid
    }

    static func item(_ book: SystemEbook) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = book.title
        attributes.displayName = book.title
        attributes.authorNames = book.author.map { [$0] }
        attributes.contentDescription = book.author.map { "Ebook by \($0)" } ?? "Ebook in Enve"
        attributes.keywords = ["ebook", "reading", "Enve"]
        let item = CSSearchableItem(uniqueIdentifier: identifier(for: book.id), domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return item
    }

    static func identifier(for bookID: String) -> String { domain + ":" + bookID }

    static func bookID(from identifier: String) -> String? {
        let prefix = domain + ":"
        guard identifier.hasPrefix(prefix), identifier.count > prefix.count else { return nil }
        return String(identifier.dropFirst(prefix.count))
    }
}
#endif
