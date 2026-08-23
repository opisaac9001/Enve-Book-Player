package com.enve.app.ui.screens.reader

import com.enve.app.data.reader.ReaderPreferences
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.ReaderEngineKind
import org.readium.r2.shared.publication.Locator

data class ReaderEngineTocItem(
    val title: String,
    val href: String,
    val depth: Int,
)

data class ReaderEngineLocation(
    val checkpoint: EpubBridgeCheckpoint,
    val locator: Locator,
    val currentPage: Int,
    val totalPages: Int,
    val sectionTitle: String,
    val userInitiated: Boolean,
)

interface ReaderEngineNavigator {
    val kind: ReaderEngineKind
    val currentLocator: Locator?
    val currentSelection: Locator?

    fun goForward()
    fun goBackward()
    fun goToProgress(fraction: Float)
    fun goToHref(href: String)
    fun goToCfi(cfi: String)
    fun goToLocator(locator: Locator)
    fun applyPreferences(preferences: ReaderPreferences)
    fun applyAnnotations(annotations: List<ReaderAnnotation>)
    fun clearSelection()
    fun clearSearch()
    fun autoScrollStep(distance: Float)
    suspend fun search(query: String, limit: Int): List<Locator>
    fun close()
}
