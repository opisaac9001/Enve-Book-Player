import Foundation
import SwiftData

enum SmartCollectionPredicateBuilder {

    nonisolated static func build(ruleGroup: SmartCollectionRuleGroup) -> Predicate<BookRecord> {

        let andRules = ruleGroup.logicOperator == .and ? ruleGroup.rules : []

        if andRules.count == 2,
            let r0 = andRules.first, r0.field == .isFinished, r0.operator == .isFalse,
            let r1 = andRules.dropFirst().first, r1.field == .progress, r1.operator == .greaterThan,
            let progressFloor = Double(r1.value), progressFloor == 0
        {
            return #Predicate<BookRecord> { record in
                !record.isFinished && !record.isDeleted && !record.isHidden && record.currentTime > 0
            }
        }

        if andRules.count == 1, let r = andRules.first, r.field == .isFinished, r.operator == .isTrue {
            return #Predicate<BookRecord> { record in
                record.isFinished && !record.isDeleted && !record.isHidden
            }
        }

        if andRules.count == 1, let r = andRules.first, r.field == .isAbandoned, r.operator == .isTrue {
            return #Predicate<BookRecord> { record in
                record.serverReadStatus == "ABANDONED"
                    && !record.isDeleted
                    && !record.isHidden
            }
        }

        if andRules.count == 1, let r = andRules.first, r.field == .isFinished, r.operator == .isFalse {
            return #Predicate<BookRecord> { record in
                !record.isFinished && !record.isDeleted && !record.isHidden
            }
        }

        if andRules.count == 1, let r = andRules.first, r.field == .dateAdded, r.operator == .greaterThan,
            let days = Int(r.value)
        {
            let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 3600))
            let distantPast = Date.distantPast
            return #Predicate<BookRecord> { record in
                !record.isDeleted && !record.isHidden && (record.addedAt ?? distantPast) > cutoff
            }
        }

        if andRules.count == 1, let r = andRules.first, r.field == .duration,
            let hours = Double(r.value)
        {
            let seconds = hours * 3600
            switch r.operator {
            case .greaterThan:
                return #Predicate<BookRecord> { record in
                    !record.isDeleted && !record.isHidden && (record.duration ?? 0) > seconds
                }
            case .lessThan:
                return #Predicate<BookRecord> { record in
                    !record.isDeleted && !record.isHidden && (record.duration ?? 0) > 0 && (record.duration ?? 0) < seconds
                }
            default:
                break
            }
        }

        if andRules.count == 1, let r = andRules.first, r.field == .releaseYear, r.operator == .equals,
            let year = Int(r.value)
        {
            return #Predicate<BookRecord> { record in
                !record.isDeleted && !record.isHidden && record.publishedYear == year
            }
        }

        if andRules.count == 1, let r = andRules.first, r.field == .author, r.operator == .equals {
            let value = r.value
            return #Predicate<BookRecord> { record in
                !record.isDeleted && !record.isHidden && record.author == value
            }
        }
        if andRules.count == 1, let r = andRules.first, r.field == .narrator, r.operator == .equals {
            let value = r.value
            return #Predicate<BookRecord> { record in
                !record.isDeleted && !record.isHidden && record.narrator == value
            }
        }

        return #Predicate<BookRecord> { record in
            !record.isDeleted && !record.isHidden
        }
    }
}
