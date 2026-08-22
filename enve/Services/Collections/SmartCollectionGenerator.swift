import Foundation

enum SmartCollectionGenerator {
    static func generateSystemCollections() -> [SmartCollection] {
        [
            currentlyListening(),
            finished(),
            abandoned(),
            unfinished(),
            recentlyAdded(),
            longBooks(),
            shortBooks(),
        ]
    }

    private static func currentlyListening() -> SmartCollection {
        SmartCollection(
            id: "system-currently-listening",
            name: "Currently Listening",
            description: "Books you're in the middle of",
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [
                    SmartCollectionRule(field: .isFinished, operator: .isFalse, value: ""),
                    SmartCollectionRule(field: .progress, operator: .greaterThan, value: "0"),
                ]
            ),
            iconName: "headphones",
            color: "systemBlue",
            isSystem: true,
            sortOrder: 1
        )
    }

    private static func finished() -> SmartCollection {
        SmartCollection(
            id: "system-finished",
            name: "Finished",
            description: "Books you've completed",
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [
                    SmartCollectionRule(field: .isFinished, operator: .isTrue, value: "")
                ]
            ),
            iconName: "checkmark.circle.fill",
            color: "systemGreen",
            isSystem: true,
            sortOrder: 2
        )
    }

    private static func abandoned() -> SmartCollection {
        SmartCollection(
            id: "system-abandoned",
            name: "Abandoned",
            description: "Books you marked as abandoned",
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [
                    SmartCollectionRule(field: .isAbandoned, operator: .isTrue, value: "")
                ]
            ),
            iconName: "flag.slash.fill",
            color: "systemOrange",
            isSystem: true,
            sortOrder: 3
        )
    }

    private static func unfinished() -> SmartCollection {
        SmartCollection(
            id: "system-unfinished",
            name: "Unfinished",
            description: "Books you haven't completed yet",
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [
                    SmartCollectionRule(field: .isFinished, operator: .isFalse, value: "")
                ]
            ),
            iconName: "book.circle.fill",
            color: "systemOrange",
            isSystem: true,
            sortOrder: 4
        )
    }

    private static func recentlyAdded() -> SmartCollection {
        SmartCollection(
            id: "system-recently-added",
            name: "Recently Added",
            description: "Books added in the last 30 days",
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [
                    SmartCollectionRule(field: .dateAdded, operator: .greaterThan, value: "30")
                ]
            ),
            iconName: "calendar",
            color: "systemPurple",
            isSystem: true,
            sortOrder: 5
        )
    }

    private static func longBooks() -> SmartCollection {
        SmartCollection(
            id: "system-long-books",
            name: "Long Books",
            description: "Books over 20 hours",
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [
                    SmartCollectionRule(field: .duration, operator: .greaterThan, value: "20")
                ]
            ),
            iconName: "book.fill",
            color: "systemRed",
            isSystem: true,
            sortOrder: 6
        )
    }

    private static func shortBooks() -> SmartCollection {
        SmartCollection(
            id: "system-short-books",
            name: "Short Books",
            description: "Books under 5 hours",
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [
                    SmartCollectionRule(field: .duration, operator: .lessThan, value: "5")
                ]
            ),
            iconName: "book.closed.fill",
            color: "systemBlue",
            isSystem: true,
            sortOrder: 7
        )
    }
}
