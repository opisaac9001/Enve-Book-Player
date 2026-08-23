package com.enve.hearth.shell

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.ui.graphics.vector.ImageVector

enum class HearthTab(val label: String, val glyph: ImageVector) {
    HEARTH("Hearth", Icons.Outlined.LocalFireDepartment),
    LIBRARY("Library", Icons.AutoMirrored.Outlined.MenuBook),
    JOURNAL("Journal", Icons.Outlined.EditNote),
}
