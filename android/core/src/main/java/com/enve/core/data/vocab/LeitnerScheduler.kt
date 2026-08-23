package com.enve.core.data.vocab

import java.util.Calendar
import java.util.concurrent.TimeUnit

object LeitnerScheduler {

    enum class Action { AGAIN, GOT_IT, MASTERED }

    data class Result(val newBox: Int, val nextReviewAt: Long?, val reviewStreak: Int)

    private val intervalDays = mapOf(1 to 1, 2 to 3, 3 to 7, 4 to 14, 5 to 30)

    fun intervalLabel(box: Int): String = when (box) {
        1 -> "1d"
        2 -> "3d"
        3 -> "1w"
        4 -> "2w"
        else -> "Done"
    }

    private fun nextReviewDate(daysAhead: Int, now: Long): Long {
        val cal = Calendar.getInstance().apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return cal.timeInMillis + TimeUnit.DAYS.toMillis(daysAhead.toLong())
    }

    fun apply(
        action: Action,
        currentBox: Int,
        currentStreak: Int,
        now: Long = System.currentTimeMillis(),
    ): Result = when (action) {
        Action.AGAIN -> Result(
            newBox = 1,
            nextReviewAt = nextReviewDate(1, now),
            reviewStreak = 0,
        )
        Action.MASTERED -> Result(
            newBox = 5,
            nextReviewAt = null,
            reviewStreak = currentStreak + 1,
        )
        Action.GOT_IT -> {
            if (currentStreak >= 3 && currentBox >= 4) {
                Result(newBox = 5, nextReviewAt = null, reviewStreak = currentStreak + 1)
            } else {
                val promoted = minOf(currentBox + 1, 4)
                Result(
                    newBox = promoted,
                    nextReviewAt = nextReviewDate(intervalDays.getValue(promoted), now),
                    reviewStreak = currentStreak + 1,
                )
            }
        }
    }
}
