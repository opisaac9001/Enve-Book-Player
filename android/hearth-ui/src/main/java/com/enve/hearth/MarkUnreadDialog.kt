package com.enve.hearth

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import com.enve.core.data.model.Book
import com.enve.hearth.design.Hearth

@Composable
internal fun MarkUnreadDialog(book: Book, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Mark as unread?") },
        text = {
            Text(
                "This clears your progress in \"${book.title}\" on this device and its connected server. " +
                    "Highlights, bookmarks and downloads are kept.",
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text("Mark as unread", color = Hearth.palette.statusError) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
