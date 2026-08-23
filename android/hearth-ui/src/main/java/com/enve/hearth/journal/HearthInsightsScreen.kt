package com.enve.hearth.journal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay
import kotlin.math.abs

@Composable
fun HearthInsightsScreen(
    onBack: () -> Unit,
    onSelectBook: (Book) -> Unit,
) {
    val vm: HearthInsightsViewModel = hiltViewModel()
    val insights by vm.insights.collectAsStateWithLifecycle()
    val palette = Hearth.palette

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "Back",
                    tint = palette.text,
                    modifier = Modifier.size(26.dp),
                )
            }
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column(Modifier.weight(1f)) {
                Overline("Patterns in the pages")
                Text("Insights", style = HearthText.ScreenTitle, color = palette.text)
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = Hearth.Spacing.XL,
                top = Hearth.Spacing.M,
                end = Hearth.Spacing.XL,
                bottom = Hearth.Spacing.XXL,
            ),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XL),
        ) {
            item { WeekCard(insights) }
            item { RhythmCard(insights) }
            if (insights.topBooks.isNotEmpty()) {
                item { TopBooksCard(insights.topBooks.take(6), onSelectBook) }
            }
            if (insights.topAuthors.isNotEmpty() || insights.topNarrators.isNotEmpty()) {
                item { CreatorsCard(insights) }
            }
            item { YearReviewCard(insights, vm::selectYear) }
        }
    }
}

@Composable
private fun WeekCard(insights: JournalInsights) {
    InsightsCard("Week over week") {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            InsightMetric(formatDuration(insights.thisWeekSeconds), "This week", Modifier.weight(1f))
            InsightMetric(formatDuration(insights.lastWeekSeconds), "Last week", Modifier.weight(1f))
        }
        Text(
            weekComparison(insights.thisWeekSeconds, insights.lastWeekSeconds),
            style = HearthText.Caption,
            color = Hearth.palette.textSecondary,
        )
    }
}

@Composable
private fun RhythmCard(insights: JournalInsights) {
    InsightsCard("Your rhythm") {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            InsightMetric(insights.currentStreak.toString(), "Current streak", Modifier.weight(1f))
            InsightMetric(insights.longestStreak.toString(), "Longest streak", Modifier.weight(1f))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            InsightMetric(insights.favoriteWeekday ?: "Unavailable", "Favorite day", Modifier.weight(1f))
            InsightMetric(
                insights.yearReview.activeDays.toString(),
                "Active days in ${insights.yearReview.year}",
                Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun TopBooksCard(
    books: List<InsightBookEntry>,
    onSelectBook: (Book) -> Unit,
) {
    val palette = Hearth.palette
    InsightsCard("Most kept company") {
        books.forEach { entry ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { onSelectBook(entry.book) }
                    .padding(vertical = Hearth.Spacing.XS),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                CoverTile(
                    model = entry.book.coverUrl,
                    contentDescription = entry.book.title,
                    modifier = Modifier.width(42.dp),
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
                    Text(
                        entry.book.title,
                        style = HearthText.Label,
                        color = palette.text,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        entry.book.author?.trim().takeUnless { it.isNullOrEmpty() } ?: "Unknown author",
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    formatDuration(entry.seconds),
                    style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun CreatorsCard(insights: JournalInsights) {
    InsightsCard("Voices you return to") {
        insights.topAuthors.firstOrNull()?.let { InsightLeader("Author", it) }
        insights.topNarrators.firstOrNull()?.let { InsightLeader("Narrator", it) }
    }
}

@Composable
private fun InsightLeader(label: String, entry: InsightNamedEntry) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
            Overline(label)
            Text(
                entry.name,
                style = HearthText.Label,
                color = palette.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(formatDuration(entry.seconds), style = HearthText.Caption, color = palette.textSecondary)
    }
}

@Composable
private fun YearReviewCard(
    insights: JournalInsights,
    onSelectYear: (Int) -> Unit,
) {
    val review = insights.yearReview
    InsightsCard("${review.year} in review") {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            items(insights.availableYears, key = { it }) { year ->
                HearthChip(
                    label = year.toString(),
                    selected = year == review.year,
                    onClick = { onSelectYear(year) },
                )
            }
        }

        Text(
            formatDuration(review.totalSeconds),
            style = hearthDisplay(40.sp),
            color = Hearth.palette.text,
        )

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            InsightMetric(review.activeDays.toString(), "Active days", Modifier.weight(1f))
            InsightMetric(review.sessions.toString(), "Sessions", Modifier.weight(1f))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            InsightMetric(review.booksFinished.toString(), "Books finished", Modifier.weight(1f))
            InsightMetric(review.favoriteMonth ?: "Unavailable", "Favorite month", Modifier.weight(1f))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            InsightMetric(formatDuration(review.listeningSeconds), "Listening", Modifier.weight(1f))
            InsightMetric(formatDuration(review.readingSeconds), "Reading", Modifier.weight(1f))
        }

        if (review.pagesRead > 0) InsightDetail("Pages turned", "%,d".format(review.pagesRead))
        review.topBook?.let { InsightDetail("Top book", it.book.title) }
        review.topAuthor?.let { InsightDetail("Top author", it.name) }
        review.topNarrator?.let { InsightDetail("Top narrator", it.name) }

        if (review.totalSeconds <= 0L && review.booksFinished == 0) {
            Text(
                "This year is waiting for its first chapter.",
                style = HearthText.Body,
                color = Hearth.palette.textSecondary,
            )
        }
    }
}

@Composable
private fun InsightMetric(
    value: String,
    label: String,
    modifier: Modifier = Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
        Text(
            value,
            style = hearthDisplay(22.sp, FontWeight.SemiBold),
            color = Hearth.palette.text,
            maxLines = 1,
        )
        Overline(label)
    }
}

@Composable
private fun InsightDetail(label: String, value: String) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = HearthText.Caption, color = palette.textSecondary)
        Spacer(Modifier.weight(1f))
        Text(
            value,
            style = HearthText.Caption.copy(fontWeight = FontWeight.Medium),
            color = palette.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
    }
}

@Composable
private fun InsightsCard(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Card)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Overline(title)
        content()
    }
}

private fun formatDuration(seconds: Long): String {
    val hours = seconds / 3_600L
    val minutes = (seconds % 3_600L) / 60L
    return when {
        hours > 0L -> "${hours}h ${minutes}m"
        else -> "${minutes}m"
    }
}

private fun weekComparison(current: Long, previous: Long): String {
    if (previous <= 0L) {
        return if (current > 0L) "A new week is on the record." else "Your next session starts the comparison."
    }
    val change = ((current - previous).toDouble() / previous.toDouble() * 100.0).toInt()
    return when {
        change == 0 -> "Right in step with last week."
        change > 0 -> "$change% more time than last week."
        else -> "${abs(change)}% less time than last week."
    }
}
