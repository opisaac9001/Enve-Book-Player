package com.enve.hearth.bookorbit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.engine.bookorbit.BookOrbitDailyPoint
import com.enve.engine.bookorbit.BookOrbitInsights
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.hearthDisplay
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.Month
import java.time.format.TextStyle
import java.util.Locale

@Composable
fun BookOrbitInsightsScreen(
    onBack: () -> Unit,
    onOpenBook: (Book) -> Unit,
) {
    val vm: BookOrbitInsightsViewModel = hiltViewModel()
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val accountId by vm.activeAccountId.collectAsStateWithLifecycle()
    val days by vm.days.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    BookOrbitScreen(
        overline = "BookOrbit",
        title = "Server insights",
        accounts = accounts,
        selectedAccountId = accountId,
        onSelectAccount = vm::selectAccount,
        onBack = onBack,
    ) {
        when (val current = state) {
            BookOrbitLoad.Loading -> BookOrbitLoadingBlock()
            BookOrbitLoad.NoAccount -> BookOrbitPlaceholder(
                headline = "No BookOrbit account",
                body = "Add a BookOrbit source to see the reading statistics your server keeps across every device.",
            )
            BookOrbitLoad.Unavailable -> BookOrbitPlaceholder(
                headline = "Nothing recorded yet",
                body = "This BookOrbit server has no statistics for your account, or it runs a build without the statistics API.",
                onRetry = vm::retry,
            )
            BookOrbitLoad.Failed -> BookOrbitPlaceholder(
                headline = "Couldn't reach BookOrbit",
                body = "The server didn't answer. Check that the source is online and try again.",
                onRetry = vm::retry,
            )
            is BookOrbitLoad.Ready -> InsightsContent(
                insights = current.value,
                days = days,
                modifier = Modifier.weight(1f),
                onSelectWindow = vm::selectWindow,
                onOpenBook = { bookId ->
                    scope.launch { vm.openBook(bookId)?.let(onOpenBook) }
                },
            )
        }
    }
}

@Composable
private fun InsightsContent(
    insights: BookOrbitInsights,
    days: Int,
    modifier: Modifier,
    onSelectWindow: (Int) -> Unit,
    onOpenBook: (Int) -> Unit,
) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = Hearth.Spacing.XL,
            top = Hearth.Spacing.M,
            end = Hearth.Spacing.XL,
            bottom = Hearth.Spacing.XXL,
        ),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XL),
    ) {
        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                items(BOOK_ORBIT_INSIGHT_WINDOWS, key = { it }) { window ->
                    HearthChip(
                        label = windowLabel(window),
                        selected = window == days,
                        onClick = { onSelectWindow(window) },
                    )
                }
            }
        }

        item { ReadingTimeCard(insights, days) }

        insights.streak?.let { streak ->
            item {
                BookOrbitCard("Streak", caption = "Counted by BookOrbit across every synced device") {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric("${streak.currentStreak}", "Current", Modifier.weight(1f))
                        BookOrbitMetric("${streak.longestStreak}", "Longest", Modifier.weight(1f))
                    }
                    if (streak.lastSevenDays.isNotEmpty()) {
                        LastSevenDays(streak.lastSevenDays)
                    }
                }
            }
        }

        insights.summary?.let { summary ->
            item {
                BookOrbitCard("Your shelf on the server") {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric("${summary.inProgressBooks}", "In progress", Modifier.weight(1f))
                        BookOrbitMetric("${summary.completedBooks}", "Finished", Modifier.weight(1f))
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric("${summary.startedBooks}", "Started", Modifier.weight(1f))
                        BookOrbitMetric(
                            "${summary.meanProgressPercent.toInt()}%",
                            "Mean progress",
                            Modifier.weight(1f),
                        )
                    }
                }
            }
        }

        insights.goal?.let { goal ->
            item {
                BookOrbitCard("${goal.year} goal") {
                    Text(
                        "${goal.completedBooks} of ${goal.goalBooks}",
                        style = hearthDisplay(32.sp, FontWeight.SemiBold),
                        color = Hearth.palette.text,
                    )
                    BookOrbitBar(
                        label = "Books finished",
                        value = "${goalPercent(goal.completedBooks, goal.goalBooks)}%",
                        fraction = goal.completedBooks.toFloat() / goal.goalBooks.coerceAtLeast(1).toFloat(),
                    )
                    insights.projection?.let { projection ->
                        BookOrbitDetailRow("On pace for", "${projection.projectedBooks} books")
                        BookOrbitDetailRow("Days left this year", "${projection.daysRemaining}")
                    }
                }
            }
        }

        if (insights.sources.isNotEmpty()) {
            item {
                val total = insights.sources.sumOf { it.readingSeconds }.coerceAtLeast(1L)
                BookOrbitCard("Where you read", caption = "Devices reporting to this server") {
                    insights.sources.forEach { slice ->
                        BookOrbitBar(
                            label = slice.label,
                            value = formatReadingTime(slice.readingSeconds),
                            fraction = slice.readingSeconds.toFloat() / total.toFloat(),
                        )
                    }
                }
            }
        }

        if (insights.heatmap.any { it.readingSeconds > 0L }) {
            item { HeatmapCard(insights.heatmap) }
        }

        if (insights.peakHours.isNotEmpty()) {
            item {
                val peak = insights.peakHours.maxByOrNull { it.readingSeconds }
                BookOrbitCard("Time of day", caption = peak?.let { "Busiest around ${hourLabel(it.hour)}" }) {
                    BookOrbitColumns(hourSeries(insights))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        listOf(0, 6, 12, 18).forEach { hour ->
                            Text(hourLabel(hour), style = HearthText.Caption, color = Hearth.palette.textTertiary)
                        }
                    }
                }
            }
        }

        if (insights.favoriteDays.isNotEmpty()) {
            item {
                val busiest = insights.favoriteDays.maxOf { it.readingSeconds }.coerceAtLeast(1L)
                BookOrbitCard("Days of the week") {
                    insights.favoriteDays.forEach { day ->
                        BookOrbitBar(
                            label = day.label,
                            value = formatReadingTime(day.readingSeconds),
                            fraction = day.readingSeconds.toFloat() / busiest.toFloat(),
                        )
                    }
                }
            }
        }

        if (insights.genres.isNotEmpty()) {
            item {
                val busiest = insights.genres.maxOf { it.readingSeconds }.coerceAtLeast(1L)
                BookOrbitCard("Genres you spend time in") {
                    insights.genres.forEach { genre ->
                        BookOrbitBar(
                            label = genre.genre,
                            value = formatReadingTime(genre.readingSeconds),
                            fraction = genre.readingSeconds.toFloat() / busiest.toFloat(),
                        )
                    }
                }
            }
        }

        insights.funnel?.let { funnel ->
            item {
                val started = funnel.stages.firstOrNull()?.count?.coerceAtLeast(1) ?: 1
                BookOrbitCard(
                    "How far books get",
                    caption = funnel.previousCompleted?.let { "Previous window finished $it" },
                ) {
                    funnel.stages.forEach { stage ->
                        BookOrbitBar(
                            label = stage.label,
                            value = "${stage.count}",
                            fraction = stage.count.toFloat() / started.toFloat(),
                        )
                    }
                }
            }
        }

        insights.completionLatency?.let { latency ->
            item {
                BookOrbitCard("Time to finish") {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric(dayLabel(latency.medianDays), "Median", Modifier.weight(1f))
                        BookOrbitMetric(dayLabel(latency.percentile90Days), "Slowest 10%", Modifier.weight(1f))
                    }
                    BookOrbitDetailRow("Books measured", "${latency.totalCompletions}")
                }
            }
        }

        if (insights.completions.isNotEmpty()) {
            item {
                val busiest = insights.completions.maxOf { it.count }.coerceAtLeast(1)
                BookOrbitCard("Books finished by month") {
                    insights.completions.takeLast(12).forEach { point ->
                        BookOrbitBar(
                            label = monthLabel(point.year, point.month),
                            value = "${point.count}",
                            fraction = point.count.toFloat() / busiest.toFloat(),
                        )
                    }
                }
            }
        }

        insights.rhythm?.let { rhythm ->
            item {
                BookOrbitCard("Rhythm") {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric("${rhythm.consistencyPercent.toInt()}%", "Consistency", Modifier.weight(1f))
                        BookOrbitMetric(
                            formatReadingTime(rhythm.averageSecondsPerDay),
                            "Average day",
                            Modifier.weight(1f),
                        )
                    }
                    BookOrbitDetailRow("Active days", "${rhythm.activeDays} of ${rhythm.totalDays}")
                }
            }
        }

        insights.challenge?.let { challenge ->
            item {
                BookOrbitCard("This month's challenge") {
                    Text(challenge.title, style = HearthText.Label, color = Hearth.palette.text)
                    Text(challenge.description, style = HearthText.Caption, color = Hearth.palette.textSecondary)
                    BookOrbitBar(
                        label = if (challenge.completed) "Complete" else "Progress",
                        value = "${challenge.progress.toInt()} / ${challenge.target.toInt()}",
                        fraction = (challenge.progress / challenge.target.coerceAtLeast(1.0)).toFloat(),
                    )
                }
            }
        }

        insights.readingDna?.let { dna ->
            item {
                BookOrbitCard("Reading DNA", caption = "${dna.booksAnalyzed} books analysed") {
                    Text(dna.archetype, style = hearthDisplay(24.sp, FontWeight.SemiBold), color = Hearth.palette.text)
                    dna.facets.forEach { facet ->
                        BookOrbitBar(facet.label, "${facet.score.toInt()}", (facet.score / 100.0).toFloat())
                    }
                }
            }
        }

        insights.diversity?.let { diversity ->
            item {
                BookOrbitCard("Diversity", caption = "${diversity.booksAnalyzed} books analysed") {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric("${diversity.score.toInt()}", "Score", Modifier.weight(1f))
                        BookOrbitMetric(diversity.label, "Verdict", Modifier.weight(1f))
                    }
                    diversity.facets.forEach { facet ->
                        BookOrbitBar(facet.label, "${facet.score.toInt()}", (facet.score / 100.0).toFloat())
                    }
                }
            }
        }

        insights.library?.let { library ->
            item {
                BookOrbitCard("Library on the server") {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric("${library.totalBooks}", "Books", Modifier.weight(1f))
                        BookOrbitMetric("${library.totalAuthors}", "Authors", Modifier.weight(1f))
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        BookOrbitMetric("${library.totalSeries}", "Series", Modifier.weight(1f))
                        BookOrbitMetric("${library.booksAddedThisYear}", "Added this year", Modifier.weight(1f))
                    }
                }
            }
        }

        insights.highlightOfTheDay?.let { highlight ->
            item {
                BookOrbitCard(
                    "Highlight of the day",
                    modifier = Modifier.clickable { onOpenBook(highlight.bookId) },
                ) {
                    Text(
                        "“${highlight.text}”",
                        style = HearthText.Body,
                        color = Hearth.palette.text,
                        maxLines = 6,
                        overflow = TextOverflow.Ellipsis,
                    )
                    listOfNotNull(highlight.bookTitle, highlight.chapterTitle)
                        .joinToString(" · ")
                        .takeIf { it.isNotBlank() }
                        ?.let { Text(it, style = HearthText.Caption, color = Hearth.palette.textSecondary) }
                    highlight.note?.let {
                        Text(it, style = HearthText.Caption, color = Hearth.palette.textTertiary)
                    }
                }
            }
        }
    }
}

@Composable
private fun ReadingTimeCard(insights: BookOrbitInsights, days: Int) {
    val series = insights.dailyReading
    val busiest = series.maxOfOrNull { it.readingSeconds }?.coerceAtLeast(1L) ?: 1L
    BookOrbitCard(
        "Reading time",
        caption = "Every device that reports to BookOrbit — separate from Enve's own history",
    ) {
        Text(
            formatReadingTime(insights.totalWindowSeconds),
            style = hearthDisplay(40.sp),
            color = Hearth.palette.text,
        )
        Text(
            "Last ${windowLabel(days).lowercase(Locale.getDefault())}",
            style = HearthText.Caption,
            color = Hearth.palette.textSecondary,
        )
        if (series.isNotEmpty()) {
            BookOrbitColumns(series.takeLast(60).map { it.readingSeconds.toFloat() / busiest.toFloat() })
        }
    }
}

@Composable
private fun LastSevenDays(days: List<Boolean>) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 4.dp)
    Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        days.takeLast(7).forEach { active ->
            Box(
                Modifier
                    .size(18.dp)
                    .clip(shape)
                    .background(
                        when {
                            !active -> palette.bg
                            eink.active -> palette.text
                            else -> palette.ember
                        },
                    )
                    .border(1.dp, palette.hairline, shape),
            )
        }
    }
}

@Composable
private fun HeatmapCard(points: List<BookOrbitDailyPoint>) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val monochrome = HearthPalette.eink()
    val byDay = points.associate { it.day to it.readingSeconds }
    val busiest = points.maxOf { it.readingSeconds }.coerceAtLeast(1L)
    val today = LocalDate.now()
    val firstDay = today.minusDays((HEATMAP_DAYS - 1).toLong())
    BookOrbitCard("The past year", caption = "Includes KOReader and Kobo sessions Enve never sees") {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            repeat(7) { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    repeat(HEATMAP_WEEKS) { column ->
                        val day = firstDay.plusDays((column * 7 + row).toLong())
                        val seconds = if (day.isAfter(today)) 0L else byDay[day.toString()] ?: 0L
                        val intensity = seconds.toFloat() / busiest.toFloat()
                        val shape = RoundedCornerShape(1.dp)
                        val fill = when {
                            !eink.active && intensity <= 0f -> palette.bg
                            !eink.active -> palette.ember.copy(alpha = 0.3f + 0.7f * intensity)
                            intensity <= 0f -> palette.bg
                            palette.isInk && intensity < 0.34f -> lerp(monochrome.text, monochrome.bg, 0.35f)
                            palette.isInk && intensity < 0.67f -> lerp(monochrome.text, monochrome.bg, 0.7f)
                            palette.isInk -> monochrome.bg
                            intensity < 0.34f -> lerp(monochrome.bg, monochrome.text, 0.35f)
                            intensity < 0.67f -> lerp(monochrome.bg, monochrome.text, 0.7f)
                            else -> monochrome.text
                        }
                        Box(
                            Modifier
                                .size(5.dp)
                                .clip(shape)
                                .background(fill)
                                .border(1.dp, palette.hairline, shape),
                        )
                    }
                }
            }
        }
    }
}

private const val HEATMAP_WEEKS = 52
private const val HEATMAP_DAYS = HEATMAP_WEEKS * 7

private fun hourSeries(insights: BookOrbitInsights): List<Float> {
    val byHour = insights.peakHours.associate { it.hour to it.readingSeconds }
    val busiest = byHour.values.maxOrNull()?.coerceAtLeast(1L) ?: 1L
    return List(24) { hour -> (byHour[hour] ?: 0L).toFloat() / busiest.toFloat() }
}

private fun windowLabel(days: Int): String = when (days) {
    365 -> "12 months"
    else -> "$days days"
}

private fun hourLabel(hour: Int): String = when {
    hour == 0 -> "12a"
    hour < 12 -> "${hour}a"
    hour == 12 -> "12p"
    else -> "${hour - 12}p"
}

private fun monthLabel(year: Int, month: Int): String =
    "${Month.of(month.coerceIn(1, 12)).getDisplayName(TextStyle.SHORT, Locale.getDefault())} $year"

private fun goalPercent(completed: Int, goal: Int): Int =
    ((completed.toFloat() / goal.coerceAtLeast(1).toFloat()) * 100f).toInt().coerceIn(0, 100)

private fun dayLabel(days: Double?): String =
    days?.let { if (it >= 10.0) "${it.toInt()}d" else "${String.format(Locale.US, "%.1f", it)}d" } ?: "—"
