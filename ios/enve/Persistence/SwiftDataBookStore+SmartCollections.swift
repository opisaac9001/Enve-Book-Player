import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func booksMatching(_ collection: SmartCollection, limit: Int? = nil) async -> [Book] {
        let worker = makeWorker()
        let candidates: [Book]
        do {
            candidates = try await worker.fetchSmartCandidates(rules: collection.rules, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.booksMatching failed: \(error)")
            return []
        }
        let needsPostFilter = collection.rules.rules.contains { rule in
            switch rule.field {
            case .genre, .isDownloaded: return true
            default: return false
            }
        }
        guard needsPostFilter else { return candidates }
        let rules = collection.rules
        return await MainActor.run {
            candidates.filter { Self.evaluateRulesInSwift(rules, for: $0) }
        }
    }

    func bookCountMatching(_ collection: SmartCollection) async -> Int {
        let worker = makeWorker()
        do {
            if let count = try await worker.fetchSmartCountIfExpressible(rules: collection.rules) {
                return count
            }
        } catch {
            AppLogger.general.error("BookStore.bookCountMatching count-only path failed: \(error)")
            return 0
        }

        return await booksMatching(collection, limit: nil).count
    }

    @MainActor
    private static func evaluateRulesInSwift(_ ruleGroup: SmartCollectionRuleGroup, for book: Book) -> Bool {
        if ruleGroup.rules.isEmpty { return true }
        switch ruleGroup.logicOperator {
        case .and: return ruleGroup.rules.allSatisfy { evaluateRule($0, for: book) }
        case .or: return ruleGroup.rules.contains { evaluateRule($0, for: book) }
        }
    }

    @MainActor
    private static func evaluateRule(_ rule: SmartCollectionRule, for book: Book) -> Bool {
        switch rule.field {
        case .author: return matchesString(book.author ?? "", rule)
        case .narrator: return matchesString(book.narrator ?? "", rule)
        case .genre: return book.genres?.contains(where: { matchesString($0, rule) }) ?? false
        case .progress: return matchesNumeric(book.progress ?? 0, rule)
        case .isFinished: return (book.progress ?? 0) >= 1.0
        case .isAbandoned: return book.serverReadStatus == "ABANDONED"
        case .isDownloaded: return LocalStorageManager.shared.isAudiobookDownloaded(book.downloadKey)
        case .dateAdded: return matchesDate(book.dateAdded, rule)
        case .lastPlayed: return matchesDate(book.lastPlayed, rule)
        case .duration: return matchesNumeric(book.duration ?? 0, rule)
        case .releaseYear:
            guard let publishedYear = book.publishedYear else { return false }
            return matchesNumeric(Double(publishedYear), rule)
        }
    }

    nonisolated private static func matchesString(_ value: String, _ rule: SmartCollectionRule) -> Bool {
        switch rule.operator {
        case .equals: return value.lowercased() == rule.value.lowercased()
        case .notEquals: return value.lowercased() != rule.value.lowercased()
        case .contains: return value.lowercased().contains(rule.value.lowercased())
        default: return false
        }
    }

    nonisolated private static func matchesNumeric(_ value: Double, _ rule: SmartCollectionRule) -> Bool {
        guard let ruleValue = Double(rule.value) else { return false }
        switch rule.operator {
        case .equals: return abs(value - ruleValue) < 0.001
        case .notEquals: return abs(value - ruleValue) >= 0.001
        case .greaterThan: return value > ruleValue
        case .lessThan: return value < ruleValue
        default: return false
        }
    }

    nonisolated private static func matchesDate(_ date: Date?, _ rule: SmartCollectionRule) -> Bool {
        guard let date, let days = Int(rule.value) else { return false }
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 3600))
        switch rule.operator {
        case .greaterThan: return date > cutoff
        case .lessThan: return date < cutoff
        default: return false
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchSmartCandidates(rules ruleGroup: SmartCollectionRuleGroup, limit: Int?) throws -> [Book] {
        let predicate = SmartCollectionPredicateBuilder.build(ruleGroup: ruleGroup)
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchSmartCountIfExpressible(rules ruleGroup: SmartCollectionRuleGroup) throws -> Int? {
        for rule in ruleGroup.rules {
            switch rule.field {
            case .genre, .isDownloaded:
                return nil
            default:
                continue
            }
        }
        let predicate = SmartCollectionPredicateBuilder.build(ruleGroup: ruleGroup)
        let descriptor = FetchDescriptor<BookRecord>(predicate: predicate)
        return try modelContext.fetchCount(descriptor)
    }
}
