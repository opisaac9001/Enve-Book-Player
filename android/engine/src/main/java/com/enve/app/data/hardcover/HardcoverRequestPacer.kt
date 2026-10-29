package com.enve.app.data.hardcover

import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Headers
import okhttp3.Headers.Companion.headersOf
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

private const val REFILL_PER_MS = 1.0 / 1_000.0
private const val DEFAULT_THROTTLE_COOLDOWN_MS = 10_000L
private const val MAX_INLINE_WAIT_MS = 30_000L
private const val MAX_RETRY_AFTER_SECONDS = Long.MAX_VALUE / 1_000
private const val MAX_THROTTLED_ATTEMPTS = 3

data class HardcoverRateObservation(
    val limit: Int?,
    val remaining: Int?,
    val retryAfterMs: Long?,
    val throttled: Boolean,
    val cooldownMs: Long? = null,
)

internal class HardcoverHttpResult(val code: Int, val body: String, val rate: HardcoverRateObservation)

internal fun hardcoverRetryAfterMs(value: String?, serverNowMs: Long): Long? {
    val trimmed = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val limitMs = MAX_RETRY_AFTER_SECONDS * 1_000
    trimmed.toDoubleOrNull()?.takeIf { it.isFinite() }?.let { seconds ->
        return (ceil(seconds.coerceIn(0.0, MAX_RETRY_AFTER_SECONDS.toDouble())) * 1_000).toLong()
    }
    val date = headersOf("Retry-After", trimmed).getDate("Retry-After") ?: return null
    return (date.time - serverNowMs).coerceIn(0, limitMs)
}

internal fun hardcoverRateObservation(code: Int, headers: Headers, nowMs: Long): HardcoverRateObservation {
    val serverNow = headers.getDate("Date")?.time ?: nowMs
    val structured = headers["RateLimit"]?.split(',')?.mapNotNull { bucket ->
        val fields = bucket.split(';').mapNotNull { part ->
            val pair = part.trim().split('=', limit = 2)
            if (pair.size == 2) pair[1].toDoubleOrNull()?.takeIf { it.isFinite() }?.let { pair[0] to it } else null
        }.toMap()
        if (fields["r"] == 0.0) fields["t"]?.let { (it.coerceAtLeast(0.0) * 1_000).toLong() } else null
    }?.maxOrNull()
    val legacy = listOf("X-RateLimit", "X-RateLimit-Daily").mapNotNull { prefix ->
        if (headers["$prefix-Remaining"]?.toIntOrNull() == 0) {
            headers["$prefix-Reset"]?.toLongOrNull()?.let { (it * 1_000 - serverNow).coerceAtLeast(0) } ?: 60_000L
        } else null
    }.maxOrNull()
    return HardcoverRateObservation(
        limit = headers["X-RateLimit-Limit"]?.trim()?.toIntOrNull(),
        remaining = headers["X-RateLimit-Remaining"]?.trim()?.toIntOrNull(),
        retryAfterMs = hardcoverRetryAfterMs(headers["Retry-After"], serverNow),
        throttled = code == 429,
        cooldownMs = listOfNotNull(structured, legacy).maxOrNull(),
    )
}

internal fun hardcoverRootFieldCount(query: String): Int {
    var depth = 0
    var parentheses = 0
    var count = 0
    var index = 0
    while (index < query.length) {
        val char = query[index]
        when {
            char == '"' -> {
                index++
                while (index < query.length && query[index] != '"') {
                    if (query[index] == '\\') index++
                    index++
                }
            }
            char == '(' -> parentheses++
            char == ')' -> parentheses--
            parentheses > 0 -> Unit
            char == '{' -> depth++
            char == '}' -> depth--
            depth == 1 && (char.isLetter() || char == '_') -> {
                var end = index
                while (end < query.length && (query[end].isLetterOrDigit() || query[end] == '_')) end++
                val name = query.substring(index, end)
                val next = query.drop(end).firstOrNull { !it.isWhitespace() }
                if (next != ':' && name != "__typename") count++
                index = end
                continue
            }
        }
        index++
    }
    return count.coerceAtLeast(1)
}

internal class HardcoverRateBudget {
    private var capacity = 1.0
    private var tokens = 1.0
    private var updatedAt: Long? = null
    private var cooldownUntil: Long? = null
    private var inFlight = 0

    fun waitFor(cost: Int, now: Long): Long {
        refill(now)
        val needed = min(cost.toDouble(), capacity)
        val slot = ceil(max(0.0, needed - tokens) / REFILL_PER_MS).toLong()
        return max(slot, cooldownRemaining(now))
    }

    fun reserve(cost: Int, now: Long) {
        refill(now)
        tokens -= cost
        inFlight++
    }

    fun cooldownRemaining(now: Long): Long = cooldownUntil?.let { (it - now).coerceAtLeast(0) } ?: 0

    fun complete(now: Long, observation: HardcoverRateObservation?) {
        inFlight = (inFlight - 1).coerceAtLeast(0)
        observation ?: return
        refill(now)
        observation.limit?.let { capacity = it.coerceAtLeast(1).toDouble() }
        observation.remaining?.let { remaining ->
            val reported = remaining.coerceAtLeast(0).toDouble()
            tokens = if (inFlight == 0) min(reported, capacity) else min(tokens, reported)
        }
        if (observation.throttled || observation.cooldownMs != null) {
            tokens = min(tokens, 0.0)
            val duration = maxOf(observation.cooldownMs ?: 0L, observation.retryAfterMs ?: if (observation.throttled) DEFAULT_THROTTLE_COOLDOWN_MS else 0L)
            val until = if (duration > Long.MAX_VALUE - now) Long.MAX_VALUE else now + duration
            cooldownUntil = cooldownUntil?.let { max(it, until) } ?: until
        }
    }

    private fun refill(now: Long) {
        val last = updatedAt
        if (last != null && now > last) tokens = min(capacity, tokens + (now - last) * REFILL_PER_MS)
        if (last == null || now > last) updatedAt = now
    }
}

class HardcoverRequestPacer internal constructor(
    private val clock: () -> Long,
    private val sleep: suspend (Long) -> Unit,
    private val maxWaitMs: Long,
) {
    constructor() : this({ System.nanoTime() / 1_000_000 }, { delay(it) }, MAX_INLINE_WAIT_MS)

    private val budget = HardcoverRateBudget()

    suspend fun acquire(cost: Int) {
        val wait = synchronized(budget) {
            val now = clock()
            val wait = budget.waitFor(cost, now)
            if (wait > maxWaitMs) throw HardcoverRateLimitedException(wait)
            budget.reserve(cost, now)
            wait
        }
        try {
            if (wait > 0) sleep(wait)
            while (true) {
                val cooldown = synchronized(budget) { budget.cooldownRemaining(clock()) }
                if (cooldown <= 0) return
                if (cooldown > maxWaitMs) throw HardcoverRateLimitedException(cooldown)
                sleep(cooldown)
            }
        } catch (error: Throwable) {
            complete(null)
            throw error
        }
    }

    fun complete(observation: HardcoverRateObservation?) {
        synchronized(budget) { budget.complete(clock(), observation) }
    }

    fun cooldownMs(): Long = synchronized(budget) { budget.cooldownRemaining(clock()) }
}

internal suspend fun hardcoverPacedExchange(
    pacer: HardcoverRequestPacer,
    cost: Int,
    ensureAccount: () -> Unit,
    exchange: suspend () -> HardcoverHttpResult,
): HardcoverHttpResult {
    repeat(MAX_THROTTLED_ATTEMPTS) {
        pacer.acquire(cost)
        val result = try {
            ensureAccount()
            exchange()
        } catch (error: Throwable) {
            pacer.complete(null)
            throw error
        }
        pacer.complete(result.rate)
        if (!result.rate.throttled) return result
    }
    throw HardcoverRateLimitedException(pacer.cooldownMs().coerceAtLeast(1_000))
}

internal suspend fun hardcoverExchange(client: OkHttpClient, request: Request): HardcoverHttpResult =
    suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                val result = try {
                    response.use {
                        HardcoverHttpResult(
                            code = it.code,
                            body = it.body?.string().orEmpty(),
                            rate = hardcoverRateObservation(it.code, it.headers, System.currentTimeMillis()),
                        )
                    }
                } catch (e: IOException) {
                    continuation.resumeWithException(e)
                    return
                }
                continuation.resume(result)
            }
        })
    }
