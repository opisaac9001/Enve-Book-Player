package com.enve.hearth.collections

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.hearth.shell.profileViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.local.CustomSmartCollection
import com.enve.core.data.local.SmartCollectionPolicy
import com.enve.core.data.local.SmartCollectionRule
import com.enve.core.data.local.SmartCollectionRuleGroup
import com.enve.core.data.local.ruleGroup
import com.enve.core.data.local.UserCollectionSummary
import com.enve.core.data.model.Book
import com.enve.engine.library.SavedBookList
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.ShelfHeader
import coil.compose.AsyncImage
import android.net.Uri
import java.io.File

@Composable
fun CollectionsScreen(
    onBack: () -> Unit,
    onOpenBook: (Book) -> Unit,
    vm: CollectionsViewModel = profileViewModel(),
) {
    val manual by vm.manual.collectAsStateWithLifecycle()
    val smart by vm.smart.collectAsStateWithLifecycle()
    val books by vm.books.collectAsStateWithLifecycle()
    val saved by vm.saved.collectAsStateWithLifecycle()
    val members by vm.members.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    var manualId by rememberSaveable { mutableStateOf<String?>(null) }
    var smartId by rememberSaveable { mutableStateOf<String?>(null) }
    var savedList by rememberSaveable { mutableStateOf<SavedBookList?>(null) }
    var manualEditor by remember { mutableStateOf<UserCollectionSummary?>(null) }
    var smartEditor by remember { mutableStateOf<CustomSmartCollection?>(null) }
    var createManual by remember { mutableStateOf(false) }
    var createSmart by remember { mutableStateOf(false) }
    var showBookPicker by remember { mutableStateOf(false) }
    val selectedManual = manual.firstOrNull { it.id == manualId }
    val selectedSmart = smart.firstOrNull { it.id == smartId }
    val selectedBooks = when {
        selectedManual != null || selectedSmart != null -> members
        savedList != null -> books.filter { book -> savedList?.let { book.uniqueKey in saved[it].orEmpty() } == true }
        else -> emptyList()
    }
    val title = selectedManual?.name ?: selectedSmart?.name ?: savedList?.title ?: "Collections"
    val back = {
        if (manualId != null || smartId != null || savedList != null) {
            manualId = null
            smartId = null
            savedList = null
        } else onBack()
    }
    BackHandler(onBack = back)
    LaunchedEffect(manualId, selectedSmart, books) {
        manualId?.let(vm::loadManual)
        selectedSmart?.let(vm::loadSmart)
    }
    LaunchedEffect(notice) {
        if (notice != null) {
            kotlinx.coroutines.delay(3500)
            vm.clearNotice()
        }
    }

    val palette = Hearth.palette
    LazyColumn(
        Modifier.fillMaxSize().background(palette.bg).statusBarsPadding(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = LocalMantelInset.current + 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = back) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text) }
                Column(Modifier.weight(1f)) {
                    Overline(if (selectedManual != null || selectedSmart != null) "Your shelf" else "Shelves of your own")
                    Text(title, style = HearthText.ScreenTitle, color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                when {
                    selectedManual != null -> {
                        TextButton(onClick = { showBookPicker = true }) { Text("Add books") }
                        TextButton(onClick = { manualEditor = selectedManual }) { Text("Edit") }
                    }
                    selectedSmart != null && !selectedSmart.id.startsWith("system-") ->
                        TextButton(onClick = { smartEditor = selectedSmart }) { Text("Edit") }
                }
            }
        }
        if (selectedManual != null || selectedSmart != null || savedList != null) {
            if (selectedBooks.isEmpty()) {
                item { Text("No books on this shelf yet.", style = HearthText.Body, color = palette.textSecondary, modifier = Modifier.padding(24.dp)) }
            } else {
                items(selectedBooks, key = Book::uniqueKey) { book ->
                    CollectionBookRow(book, onOpen = { onOpenBook(book) }, onRemove = selectedManual?.let { collection ->
                        { vm.setMember(collection.id, book, false) }
                    })
                }
            }
        } else {
            item { ShelfHeader("Smart shelves", Modifier.fillMaxWidth().padding(horizontal = 24.dp), "New rule") { createSmart = true } }
            items(smart, key = CustomSmartCollection::id) { collection ->
                val count = remember(collection, books) {
                    if (collection.rulesJson == null) books.count { SmartCollectionPolicy.matches(collection, it) }
                    else collection.ruleGroup().let { group -> books.count { SmartCollectionPolicy.matches(group, it) } }
                }
                CollectionRow(collection.name, collection.description, count, collection.id.startsWith("system-"),
                    iconName = collection.iconName, colorHex = collection.colorHex, coverPath = collection.coverPath) {
                    smartId = collection.id
                }
            }
            item { ShelfHeader("Saved books", Modifier.fillMaxWidth().padding(horizontal = 24.dp)) }
            items(SavedBookList.entries) { list ->
                CollectionRow(list.title, null, saved[list].orEmpty().size, true) { savedList = list }
            }
            item { ShelfHeader("Your shelves", Modifier.fillMaxWidth().padding(horizontal = 24.dp), "New shelf") { createManual = true } }
            if (manual.isEmpty()) {
                item { Text("Create a shelf and choose its books.", style = HearthText.Body, color = palette.textSecondary, modifier = Modifier.padding(horizontal = 24.dp)) }
            }
            items(manual, key = UserCollectionSummary::id) { collection ->
                CollectionRow(collection.name, collection.description, collection.bookCount, false,
                    iconName = collection.iconName, colorHex = collection.colorHex, coverPath = collection.coverPath) { manualId = collection.id }
            }
        }
        notice?.let { message -> item { Text(message, color = palette.ember, modifier = Modifier.padding(horizontal = 24.dp)) } }
    }

    if (createManual || manualEditor != null) {
        ManualEditor(
            collection = manualEditor,
            notice = notice,
            onDismiss = {
                createManual = false
                manualEditor = null
            },
            onSave = { name, details, icon, color, coverUri, removeCover ->
                vm.saveManual(manualEditor?.id, name, details, icon, color, coverUri, removeCover) {
                    createManual = false
                    manualEditor = null
                }
            },
            onDelete = manualEditor?.let { collection ->
                {
                    vm.deleteManual(collection.id)
                    manualId = null
                    manualEditor = null
                }
            },
        )
    }
    if (createSmart || smartEditor != null) {
        SmartEditor(
            collection = smartEditor,
            notice = notice,
            onDismiss = {
                createSmart = false
                smartEditor = null
            },
            onSave = { name, details, ruleGroup, icon, color, coverUri, removeCover ->
                vm.saveSmart(smartEditor, name, details, ruleGroup, icon, color, coverUri, removeCover) {
                    createSmart = false
                    smartEditor = null
                }
            },
            onDelete = smartEditor?.let { collection ->
                {
                    vm.deleteSmart(collection.id)
                    smartId = null
                    smartEditor = null
                }
            },
        )
    }
    if (showBookPicker && selectedManual != null) {
        BookPicker(books, members.mapTo(mutableSetOf(), Book::uniqueKey), onToggle = { book, included ->
            vm.setMember(selectedManual.id, book, included)
        }, onDismiss = { showBookPicker = false })
    }
}

@Composable
private fun CollectionRow(
    name: String,
    description: String?,
    count: Int,
    system: Boolean,
    iconName: String = "folder",
    colorHex: String? = null,
    coverPath: String? = null,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    val icon = when {
        system -> Icons.Outlined.AutoStories
        iconName == "book" -> Icons.Outlined.AutoStories
        iconName == "star" -> Icons.Outlined.StarBorder
        iconName == "heart" -> Icons.Outlined.FavoriteBorder
        else -> Icons.Outlined.Folder
    }
    val tint = colorHex?.let { runCatching { Color(android.graphics.Color.parseColor(it)) }.getOrNull() } ?: palette.ember
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 24.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (coverPath != null) {
            AsyncImage(model = File(coverPath), contentDescription = null,
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
        } else Icon(icon, null, tint = tint, modifier = Modifier.size(28.dp))
        Column(Modifier.weight(1f)) {
            Text(name, style = HearthText.Label, color = palette.text)
            description?.let { Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 2) }
        }
        Text(count.toString(), style = HearthText.Caption, color = palette.textSecondary)
    }
}

@Composable
private fun CollectionBookRow(book: Book, onOpen: () -> Unit, onRemove: (() -> Unit)?) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 24.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(book.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            book.author?.let { Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1) }
        }
        onRemove?.let { TextButton(onClick = it) { Text("Remove") } }
    }
}

@Composable
private fun ManualEditor(
    collection: UserCollectionSummary?,
    notice: String?,
    onDismiss: () -> Unit,
    onSave: (String, String?, String, String, String?, Boolean) -> Unit,
    onDelete: (() -> Unit)?,
) {
    var name by remember(collection?.id) { mutableStateOf(collection?.name.orEmpty()) }
    var description by remember(collection?.id) { mutableStateOf(collection?.description.orEmpty()) }
    var icon by remember(collection?.id) { mutableStateOf(collection?.iconName ?: "folder") }
    var color by remember(collection?.id) { mutableStateOf(collection?.colorHex ?: "#F5921A") }
    var coverUri by remember(collection?.id) { mutableStateOf<String?>(null) }
    var removeCover by remember(collection?.id) { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var attemptedSave by remember(collection?.id) { mutableStateOf(false) }
    var saving by remember(collection?.id) { mutableStateOf(false) }
    LaunchedEffect(notice) {
        if (attemptedSave && notice != null) saving = false
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (collection == null) "New shelf" else "Edit shelf") },
        text = {
            Column(Modifier.heightIn(max = 380.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(description, { description = it }, label = { Text("Description") }, maxLines = 3)
                CollectionCoverPicker(collection?.coverPath?.takeUnless { removeCover }, coverUri,
                    onSelect = { coverUri = it; removeCover = false },
                    onRemove = { coverUri = null; removeCover = true })
                ChoiceRow(listOf("folder", "book", "star", "heart"), icon) { icon = it }
                ChoiceRow(listOf("#F5921A", "#3888DC", "#8B5CF6", "#2AA875"), color) { color = it }
                if (attemptedSave && notice != null) Text(notice, style = HearthText.Caption, color = Hearth.palette.statusError)
                onDelete?.let { TextButton(onClick = { confirmDelete = true }) { Text("Delete shelf") } }
            }
        },
        confirmButton = { Button(onClick = {
            attemptedSave = true
            saving = true
            onSave(name.trim(), description, icon, color, coverUri, removeCover)
        }, enabled = name.isNotBlank() && !saving) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete this shelf?") },
        text = { Text("The books stay in your library.") },
        confirmButton = { TextButton(onClick = { onDelete?.invoke(); confirmDelete = false }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
private fun CollectionCoverPicker(
    coverPath: String?,
    selectedUri: String?,
    onSelect: (String) -> Unit,
    onRemove: () -> Unit,
) {
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri?.let { onSelect(it.toString()) }
    }
    val image = selectedUri?.let(Uri::parse) ?: coverPath?.let(::File)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (image != null) {
            AsyncImage(model = image, contentDescription = "Shelf cover",
                modifier = Modifier.size(56.dp).clip(RoundedCornerShape(10.dp)), contentScale = ContentScale.Crop)
        }
        TextButton(onClick = { picker.launch("image/*") }) { Text(if (image == null) "Choose cover" else "Change cover") }
        if (image != null) TextButton(onClick = onRemove) { Text("Remove") }
    }
}

@Composable
private fun SmartEditor(
    collection: CustomSmartCollection?,
    notice: String?,
    onDismiss: () -> Unit,
    onSave: (String, String?, SmartCollectionRuleGroup, String, String, String?, Boolean) -> Unit,
    onDelete: (() -> Unit)?,
) {
    var name by remember(collection?.id) { mutableStateOf(collection?.name.orEmpty()) }
    var description by remember(collection?.id) { mutableStateOf(collection?.description.orEmpty()) }
    var icon by remember(collection?.id) { mutableStateOf(collection?.iconName ?: "folder") }
    var color by remember(collection?.id) { mutableStateOf(collection?.colorHex ?: "#F5921A") }
    var coverUri by remember(collection?.id) { mutableStateOf<String?>(null) }
    var removeCover by remember(collection?.id) { mutableStateOf(false) }
    var logic by remember(collection?.id) { mutableStateOf(collection?.ruleGroup()?.logicOperator ?: "AND") }
    var rules by remember(collection?.id) { mutableStateOf(collection?.ruleGroup()?.rules.orEmpty()) }
    var field by remember(collection?.id) { mutableStateOf("author") }
    var operator by remember(collection?.id) { mutableStateOf("contains") }
    var value by remember(collection?.id) { mutableStateOf("") }
    var fieldMenu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var attemptedSave by remember(collection?.id) { mutableStateOf(false) }
    var saving by remember(collection?.id) { mutableStateOf(false) }
    LaunchedEffect(notice) {
        if (attemptedSave && notice != null) saving = false
    }
    val fields = listOf("author", "narrator", "genre", "duration", "progress", "isFinished", "isAbandoned", "isDownloaded", "dateAdded", "lastPlayed", "releaseYear", "mediaType", "readStatus", "search")
    val booleanField = field in setOf("isFinished", "isAbandoned", "isDownloaded")
    val numberField = field in setOf("duration", "progress", "releaseYear", "dateAdded", "lastPlayed")
    val operators = when {
        booleanField -> listOf("isTrue", "isFalse")
        field in setOf("dateAdded", "lastPlayed") -> listOf("greaterThan", "lessThan")
        numberField -> listOf("equals", "notEquals", "greaterThan", "lessThan")
        else -> listOf("equals", "notEquals", "contains")
    }
    val validValue = booleanField || if (numberField) value.toDoubleOrNull() != null else value.isNotBlank()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (collection == null) "New smart shelf" else "Edit smart shelf") },
        text = {
            Column(Modifier.heightIn(max = 380.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(description, { description = it }, label = { Text("Description") }, maxLines = 2)
                CollectionCoverPicker(collection?.coverPath?.takeUnless { removeCover }, coverUri,
                    onSelect = { coverUri = it; removeCover = false },
                    onRemove = { coverUri = null; removeCover = true })
                ChoiceRow(listOf("folder", "book", "star", "heart"), icon) { icon = it }
                ChoiceRow(listOf("#F5921A", "#3888DC", "#8B5CF6", "#2AA875"), color) { color = it }
                Text("Rules", style = HearthText.Label)
                ChoiceRow(listOf("AND", "OR"), logic) { logic = it }
                rules.forEachIndexed { index, rule ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("${rule.field.ruleLabel()} ${rule.operator.ruleLabel()} ${rule.value}", modifier = Modifier.weight(1f), style = HearthText.Caption)
                        TextButton(onClick = { rules = rules.filterIndexed { i, _ -> i != index } }) { Text("Remove") }
                    }
                }
                Text("Add a rule", style = HearthText.Label)
                Box {
                    TextButton(onClick = { fieldMenu = true }) { Text("Field: ${field.ruleLabel()}") }
                    DropdownMenu(expanded = fieldMenu, onDismissRequest = { fieldMenu = false }) {
                        fields.forEach { option ->
                            DropdownMenuItem(text = { Text(option.ruleLabel()) }, onClick = {
                                field = option
                                operator = when {
                                    option in setOf("isFinished", "isAbandoned", "isDownloaded") -> "isTrue"
                                    option in setOf("duration", "progress", "releaseYear", "dateAdded", "lastPlayed") -> "greaterThan"
                                    else -> "contains"
                                }
                                value = ""
                                fieldMenu = false
                            })
                        }
                    }
                }
                ChoiceRow(operators, operator) { operator = it }
                if (!booleanField) {
                    val hint = when (field) {
                        "duration" -> "Hours"
                        "progress" -> "0.0 to 1.0"
                        "dateAdded", "lastPlayed" -> "Days ago"
                        else -> "Value"
                    }
                    OutlinedTextField(value, { value = it }, label = { Text(hint) }, singleLine = true)
                }
                TextButton(onClick = {
                    rules = rules + SmartCollectionRule(field, operator, value.trim())
                    value = ""
                }, enabled = validValue) { Text("Add rule") }
                if (attemptedSave && notice != null) Text(notice, style = HearthText.Caption, color = Hearth.palette.statusError)
                onDelete?.let { TextButton(onClick = { confirmDelete = true }) { Text("Delete smart shelf") } }
            }
        },
        confirmButton = { Button(onClick = {
            attemptedSave = true
            saving = true
            onSave(name.trim(), description, SmartCollectionRuleGroup(logic, rules), icon, color, coverUri, removeCover)
        }, enabled = name.isNotBlank() && rules.isNotEmpty() && !saving) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete this smart shelf?") },
        text = { Text("The books stay in your library.") },
        confirmButton = { TextButton(onClick = { onDelete?.invoke(); confirmDelete = false }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
private fun ChoiceRow(options: List<String>, selected: String, onSelect: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { option -> HearthChip(label = option.ruleLabel(),
            selected = option == selected, onClick = { onSelect(option) }) }
    }
}

private fun String.ruleLabel(): String = when (this) {
    "AND" -> "Match every rule"
    "OR" -> "Match any rule"
    "isTrue" -> "is true"
    "isFalse" -> "is false"
    "notEquals" -> "does not equal"
    "greaterThan" -> "greater than"
    "lessThan" -> "less than"
    "isFinished" -> "Finished status"
    "isAbandoned" -> "Abandoned"
    "isDownloaded" -> "Downloaded"
    "dateAdded" -> "Date added"
    "lastPlayed" -> "Last played"
    "releaseYear" -> "Release year"
    "mediaType" -> "Media type"
    "readStatus" -> "Reading status"
    else -> replace('_', ' ').replaceFirstChar(Char::uppercaseChar)
}

@Composable
private fun BookPicker(books: List<Book>, members: Set<String>, onToggle: (Book, Boolean) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val results = remember(query, books) {
        if (query.isBlank()) emptyList() else books.filter {
            it.title.contains(query, true) || it.author?.contains(query, true) == true
        }.take(100)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add books") },
        text = {
            Column {
                OutlinedTextField(query, { query = it }, label = { Text("Search your library") }, singleLine = true)
                LazyColumn(Modifier.heightIn(max = 380.dp)) {
                    items(results, key = Book::uniqueKey) { book ->
                        val included = book.uniqueKey in members
                        Row(Modifier.fillMaxWidth().clickable { onToggle(book, !included) }, verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = included, onCheckedChange = { onToggle(book, it) })
                            Column {
                                Text(book.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                book.author?.let { Text(it, style = HearthText.Caption) }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}
