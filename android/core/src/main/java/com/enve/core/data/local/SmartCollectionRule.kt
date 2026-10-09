package com.enve.core.data.local

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class SmartCollectionRuleGroup(
    val logicOperator: String = "AND",
    val rules: List<SmartCollectionRule> = emptyList(),
)

@Serializable
data class SmartCollectionRule(
    val field: String,
    val operator: String,
    val value: String,
)

fun CustomSmartCollection.ruleGroup(): SmartCollectionRuleGroup =
    rulesJson?.let { Json.decodeFromString<SmartCollectionRuleGroup>(it) } ?: SmartCollectionRuleGroup(
        rules = buildList {
            mediaType?.let { add(SmartCollectionRule("mediaType", "equals", it)) }
            when (status) {
                "IN_PROGRESS" -> {
                    add(SmartCollectionRule("isFinished", "isFalse", ""))
                    add(SmartCollectionRule("progress", "greaterThan", "0"))
                    add(SmartCollectionRule("readStatus", "notEquals", "ON_HOLD"))
                }
                "FINISHED" -> add(SmartCollectionRule("isFinished", "isTrue", ""))
                "UNFINISHED" -> add(SmartCollectionRule("isFinished", "isFalse", ""))
                "UNREAD" -> {
                    add(SmartCollectionRule("progress", "equals", "0"))
                    add(SmartCollectionRule("readStatus", "equals", "UNREAD"))
                }
                "ON_HOLD" -> add(SmartCollectionRule("readStatus", "equals", "ON_HOLD"))
                "ABANDONED" -> add(SmartCollectionRule("isAbandoned", "isTrue", ""))
            }
            when (length) {
                "LONG" -> add(SmartCollectionRule("duration", "greaterThan", "20"))
                "SHORT" -> {
                    add(SmartCollectionRule("duration", "greaterThan", "0"))
                    add(SmartCollectionRule("duration", "lessThan", "5"))
                }
            }
            addedWithinDays?.let { add(SmartCollectionRule("dateAdded", "greaterThan", it.toString())) }
            query?.takeIf(String::isNotBlank)?.let { add(SmartCollectionRule("search", "contains", it)) }
        },
    )
