package com.enve.hearth.podcasts

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastRoutine
import com.enve.engine.podcasts.PodcastRoutineLimits
import com.enve.engine.podcasts.PodcastRoutinePick
import com.enve.engine.podcasts.PodcastRoutineRule
import com.enve.engine.podcasts.PodcastSubscription
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI

fun LazyListScope.podcastRoutineItems(state: PodcastRoutinesUiState, vm: PodcastRoutinesViewModel) {
    item {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            Text(
                "Saved lineups of your shows. Episodes are chosen fresh each time you press Play, and Up Next only changes once something is ready.",
                style = HearthText.Caption,
                color = Hearth.palette.textSecondary,
            )
            RunStatus(state, vm)
        }
    }
    when {
        state.subscriptions.isEmpty() -> item {
            RoutinesEmpty("No shows yet", "Routines are built from the podcast feeds you subscribe to in Enve.")
        }
        state.routines.isEmpty() -> item {
            RoutinesEmpty("No routines yet", "Make one for the morning walk or a long drive.")
        }
        else -> items(state.routines, key = PodcastRoutine::id) { routine ->
            if (state.editingRoutineId == routine.id) {
                RoutineEditor(routine, state, vm)
            } else {
                RoutineRow(routine, state, vm)
            }
        }
    }
    item {
        Box(Modifier.padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.M)) {
            EmberButton(
                "New routine",
                onClick = { if (state.canCreate) vm.create() },
                leadingIcon = Icons.Outlined.Add,
                modifier = Modifier.dimmedUnless(state.canCreate),
            )
        }
    }
}

@Composable
private fun RunStatus(state: PodcastRoutinesUiState, vm: PodcastRoutinesViewModel) {
    val palette = Hearth.palette
    val run = state.run
    val runningId = run.runningRoutineId
    val lastRun = run.lastRun
    when {
        runningId != null -> PodcastCard {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                CircularProgressIndicator(color = palette.ember, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                Text(
                    "Choosing episodes for ${state.routines.firstOrNull { it.id == runningId }?.name ?: "your routine"}…",
                    style = HearthText.Body,
                    color = palette.text,
                    modifier = Modifier.weight(1f),
                )
            }
            QuietButton("Cancel", onClick = vm::cancelRun)
        }
        lastRun != null -> PodcastCard {
            Text(
                if (lastRun.didPlay) {
                    "Playing ${if (lastRun.queuedCount == 1) "1 episode" else "${lastRun.queuedCount} episodes"} from ${lastRun.routineName}"
                } else {
                    "Nothing to play from ${lastRun.routineName}"
                },
                style = hearthUI(14.sp, FontWeight.SemiBold),
                color = if (lastRun.didPlay) palette.text else palette.statusWarn,
            )
            if (!lastRun.didPlay) Text("Up Next wasn't changed.", style = HearthText.Caption, color = palette.textSecondary)
            if (lastRun.wasOffline) {
                Text("You're offline, so only downloaded episodes were considered.", style = HearthText.Caption, color = palette.textSecondary)
            }
            lastRun.explanations.forEach { outcome ->
                Column {
                    Text(outcome.showTitle, style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = palette.text)
                    Text(outcome.note.orEmpty(), style = HearthText.Caption, color = palette.textSecondary)
                }
            }
            QuietButton("Dismiss", onClick = vm::dismissResult)
        }
        run.error != null -> PodcastCard {
            Text(run.error, style = HearthText.Body, color = palette.statusError)
            QuietButton("Dismiss", onClick = vm::dismissResult)
        }
    }
}

@Composable
private fun RoutineRow(routine: PodcastRoutine, state: PodcastRoutinesUiState, vm: PodcastRoutinesViewModel) {
    val palette = Hearth.palette
    val index = state.routines.indexOf(routine)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.XS),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            Modifier.weight(1f).clickable(role = Role.Button, onClickLabel = "Edit ${routine.name}") { vm.edit(routine.id) }
                .padding(vertical = Hearth.Spacing.S),
        ) {
            Text(routine.name, style = hearthUI(15.sp, FontWeight.Medium), color = palette.text)
            Text(routineSummary(routine), style = HearthText.Caption, color = palette.textSecondary)
        }
        GlyphButton(Icons.Outlined.KeyboardArrowUp, "Move ${routine.name} up", enabled = index > 0) { vm.move(routine, -1) }
        GlyphButton(Icons.Outlined.KeyboardArrowDown, "Move ${routine.name} down", enabled = index < state.routines.lastIndex) { vm.move(routine, 1) }
        PlayRoutine(routine, state, vm)
    }
}

@Composable
private fun RoutineEditor(routine: PodcastRoutine, state: PodcastRoutinesUiState, vm: PodcastRoutinesViewModel) {
    val palette = Hearth.palette
    var name by remember(routine.id) { mutableStateOf(routine.name) }
    var confirmingDelete by rememberSaveable(routine.id) { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.S),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(routine.name, style = hearthDisplay(20.sp, FontWeight.SemiBold), color = palette.text, modifier = Modifier.weight(1f))
            Text(
                "Done",
                style = HearthText.Caption,
                color = palette.ember,
                modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                    .clickable(role = Role.Button) { vm.edit(null) }
                    .padding(Hearth.Spacing.S),
            )
        }
        OutlinedTextField(
            value = name,
            onValueChange = {
                name = it
                vm.rename(routine, it)
            },
            label = { Text("Name") },
            placeholder = { Text("Morning walk") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Overline("Shows, in play order")
        if (routine.rules.isEmpty()) {
            Text("Add a show to choose which episodes this routine plays.", style = HearthText.Caption, color = palette.textSecondary)
        }
        routine.rules.forEachIndexed { index, rule ->
            RuleCard(routine, rule, index, state.subscriptions, vm)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
            QuietButton(
                "Add a show",
                onClick = { vm.addRule(routine) },
                modifier = Modifier.dimmedUnless(routine.rules.size < PodcastRoutineLimits.MAX_RULES && state.subscriptions.isNotEmpty()),
            )
            if (state.run.runningRoutineId == routine.id) {
                CircularProgressIndicator(color = palette.ember, modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
            } else {
                EmberButton(
                    "Play",
                    onClick = { vm.play(routine) },
                    leadingIcon = Icons.Filled.PlayArrow,
                    modifier = Modifier.dimmedUnless(routine.rules.isNotEmpty()),
                )
            }
        }
        if (confirmingDelete) {
            PodcastCard {
                Text("Delete this routine?", style = hearthUI(14.sp, FontWeight.SemiBold), color = palette.text)
                Text("Your subscriptions, downloads and listening progress aren't affected.", style = HearthText.Caption, color = palette.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    EmberButton("Delete routine", onClick = { vm.delete(routine) }, tint = palette.statusError)
                    QuietButton("Cancel", onClick = { confirmingDelete = false })
                }
            }
        } else {
            QuietButton("Delete routine", onClick = { confirmingDelete = true })
        }
    }
}

@Composable
private fun RuleCard(
    routine: PodcastRoutine,
    rule: PodcastRoutineRule,
    index: Int,
    subscriptions: List<PodcastSubscription>,
    vm: PodcastRoutinesViewModel,
) {
    val palette = Hearth.palette
    var choosingShow by remember { mutableStateOf(false) }
    val pick = rule.pick
    PodcastCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                Text(
                    "${rule.showTitle} ▾",
                    style = hearthUI(15.sp, FontWeight.SemiBold),
                    color = palette.text,
                    modifier = Modifier.sizeIn(minHeight = 48.dp)
                        .clickable(role = Role.Button, onClickLabel = "Choose which subscribed show this step uses") { choosingShow = true }
                        .padding(vertical = Hearth.Spacing.M),
                )
                DropdownMenu(
                    expanded = choosingShow,
                    onDismissRequest = { choosingShow = false },
                    modifier = Modifier.background(palette.bgElevated),
                ) {
                    subscriptions.forEach { subscription ->
                        DropdownMenuItem(
                            text = { Text(subscription.title, style = HearthText.Body, color = palette.text) },
                            onClick = {
                                choosingShow = false
                                vm.setShow(routine, rule, subscription)
                            },
                        )
                    }
                }
            }
            GlyphButton(Icons.Outlined.KeyboardArrowUp, "Move ${rule.showTitle} earlier", enabled = index > 0) { vm.moveRule(routine, rule, -1) }
            GlyphButton(Icons.Outlined.KeyboardArrowDown, "Move ${rule.showTitle} later", enabled = index < routine.rules.lastIndex) { vm.moveRule(routine, rule, 1) }
            GlyphButton(Icons.Outlined.Delete, "Remove ${rule.showTitle}") { vm.removeRule(routine, rule) }
        }
        if (subscriptions.none { PodcastFeedUrl.key(it.feedUrl) == PodcastFeedUrl.key(rule.feedUrl) }) {
            Text("You're no longer subscribed to this show, so it will be skipped.", style = HearthText.Caption, color = palette.statusWarn)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            HearthChip("Newest unplayed", selected = pick == PodcastRoutinePick.NewestUnplayed, onClick = {
                vm.setPick(routine, rule, PodcastRoutinePick.NewestUnplayed)
            })
            HearthChip("Next in order", selected = pick is PodcastRoutinePick.NextUnplayed, onClick = {
                if (pick !is PodcastRoutinePick.NextUnplayed) vm.setPick(routine, rule, PodcastRoutinePick.NextUnplayed(1))
            })
        }
        if (pick is PodcastRoutinePick.NextUnplayed) {
            val counts = PodcastRoutineLimits.episodeCounts
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (pick.count == 1) "Next episode" else "Next ${pick.count} episodes",
                    style = HearthText.Body,
                    color = palette.text,
                    modifier = Modifier.weight(1f),
                )
                QuietButton("−", onClick = {
                    if (pick.count > counts.first) vm.setPick(routine, rule, PodcastRoutinePick.NextUnplayed(pick.count - 1))
                }, modifier = Modifier.dimmedUnless(pick.count > counts.first))
                QuietButton("+", onClick = {
                    if (pick.count < counts.last) vm.setPick(routine, rule, PodcastRoutinePick.NextUnplayed(pick.count + 1))
                }, modifier = Modifier.padding(start = Hearth.Spacing.S).dimmedUnless(pick.count < counts.last))
            }
        }
        Text(
            if (pick == PodcastRoutinePick.NewestUnplayed) {
                "The latest episode you haven't finished, resuming where you left off."
            } else {
                "Continues in order after the last episode you played, without skipping ahead."
            },
            style = HearthText.Caption,
            color = palette.textSecondary,
        )
    }
}

@Composable
private fun PlayRoutine(routine: PodcastRoutine, state: PodcastRoutinesUiState, vm: PodcastRoutinesViewModel) {
    if (state.run.runningRoutineId == routine.id) {
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = Hearth.palette.ember, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
        }
    } else {
        GlyphButton(Icons.Filled.PlayArrow, "Play ${routine.name}", enabled = routine.rules.isNotEmpty(), prominent = true) { vm.play(routine) }
    }
}

@Composable
private fun GlyphButton(
    icon: ImageVector,
    label: String,
    enabled: Boolean = true,
    prominent: Boolean = false,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Box(
        Modifier.size(48.dp).clip(RoundedCornerShape(50))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .dimmedUnless(enabled),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = if (prominent) palette.ember else palette.textSecondary, modifier = Modifier.size(if (prominent) 26.dp else 22.dp))
    }
}

@Composable
internal fun PodcastCard(content: @Composable ColumnScope.() -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.bgElevated).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        content = content,
    )
}

@Composable
private fun RoutinesEmpty(title: String, detail: String) {
    Column(Modifier.fillMaxWidth().padding(Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        Text(title, style = hearthDisplay(19.sp, FontWeight.SemiBold), color = Hearth.palette.text)
        Text(detail, style = HearthText.Caption, color = Hearth.palette.textSecondary)
    }
}

internal fun Modifier.dimmedUnless(enabled: Boolean): Modifier = if (enabled) this else then(Modifier.alpha(0.5f))

private fun routineSummary(routine: PodcastRoutine): String {
    if (routine.rules.isEmpty()) return "No shows yet"
    val shows = routine.rules.mapTo(mutableSetOf()) { PodcastFeedUrl.key(it.feedUrl) }.size
    val episodes = routine.rules.sumOf { it.pick.maximumEpisodes }
    val showText = if (shows == 1) "1 show" else "$shows shows"
    val episodeText = if (episodes == 1) "1 episode" else "up to $episodes episodes"
    return "$showText · $episodeText"
}
