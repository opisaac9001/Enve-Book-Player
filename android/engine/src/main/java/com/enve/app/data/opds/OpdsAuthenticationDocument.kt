package com.enve.app.data.opds

import com.enve.app.data.repository.OpdsFeedParser
import com.enve.app.data.repository.isHttpUrl
import com.enve.core.data.util.nonBlankStringOrNull
import com.enve.core.data.util.objects
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

const val OPDS_AUTHENTICATION_ACCEPT =
    "application/opds-authentication+json, application/vnd.opds.authentication.v1.0+json"

enum class OpdsAuthenticationFlow {
    BASIC,
    OAUTH_PASSWORD,
    OAUTH_IMPLICIT,
    UNSUPPORTED,
}

data class OpdsAuthenticationLabels(
    val login: String? = null,
    val password: String? = null,
)

data class OpdsAuthenticationMethod(
    val type: String,
    val flow: OpdsAuthenticationFlow,
    val labels: OpdsAuthenticationLabels = OpdsAuthenticationLabels(),
    val authenticateUrl: String? = null,
    val refreshUrl: String? = null,
)

data class OpdsAuthenticationDocument(
    val id: String?,
    val title: String?,
    val description: String?,
    val methods: List<OpdsAuthenticationMethod>,
    val helpUrls: List<String> = emptyList(),
)

fun parseOpdsAuthenticationDocument(payload: String?, baseUrl: String): OpdsAuthenticationDocument? {
    val text = payload?.trim()?.takeIf { it.startsWith("{") } ?: return null
    val root = runCatching { authJson.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
    val methods = root["authentication"].objects().mapNotNull { parseMethod(it, baseUrl) }
    if (methods.isEmpty()) return null
    return OpdsAuthenticationDocument(
        id = root["id"].nonBlankStringOrNull(),
        title = root["title"].nonBlankStringOrNull(),
        description = root["description"].nonBlankStringOrNull(),
        methods = methods,
        helpUrls = root["links"].objects()
            .filter { it.hasRel("help") }
            .mapNotNull { resolveHttp(baseUrl, it["href"].nonBlankStringOrNull()) },
    )
}

private fun parseMethod(node: JsonObject, baseUrl: String): OpdsAuthenticationMethod? {
    val type = node["type"].nonBlankStringOrNull()?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val links = node["links"].objects()
    val labels = node["labels"] as? JsonObject
    return OpdsAuthenticationMethod(
        type = type,
        flow = flowFor(type),
        labels = OpdsAuthenticationLabels(
            login = labels?.get("login").nonBlankStringOrNull(),
            password = labels?.get("password").nonBlankStringOrNull(),
        ),
        authenticateUrl = links.firstOrNull { it.hasRel("authenticate") }
            ?.let { resolveHttp(baseUrl, it["href"].nonBlankStringOrNull()) },
        refreshUrl = links.firstOrNull { it.hasRel("refresh") }
            ?.let { resolveHttp(baseUrl, it["href"].nonBlankStringOrNull()) },
    )
}

private fun flowFor(type: String): OpdsAuthenticationFlow {
    val normalized = type.trim().lowercase()
        .removePrefix("http://opds-spec.org/auth/")
        .removePrefix("https://opds-spec.org/auth/")
    return when (normalized) {
        "basic" -> OpdsAuthenticationFlow.BASIC
        "oauth/password" -> OpdsAuthenticationFlow.OAUTH_PASSWORD
        "oauth/implicit" -> OpdsAuthenticationFlow.OAUTH_IMPLICIT
        else -> OpdsAuthenticationFlow.UNSUPPORTED
    }
}

private fun resolveHttp(baseUrl: String, href: String?): String? =
    href?.takeIf { it.isNotBlank() }
        ?.let { OpdsFeedParser.resolve(baseUrl, it) }
        ?.takeIf(::isHttpUrl)

private fun JsonObject.hasRel(rel: String): Boolean =
    when (val value = this["rel"]) {
        is JsonArray -> value.any { it.nonBlankStringOrNull()?.equals(rel, ignoreCase = true) == true }
        else -> value.nonBlankStringOrNull()?.equals(rel, ignoreCase = true) == true
    }

private val authJson = Json { ignoreUnknownKeys = true; isLenient = true }
