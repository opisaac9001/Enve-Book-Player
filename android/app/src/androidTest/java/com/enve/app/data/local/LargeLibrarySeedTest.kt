package com.enve.app.data.local

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.playback.AndroidAutoDebugEntryPoint
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.CachedLibrary
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import com.enve.engine.prefs.HearthStartTab
import dagger.hilt.android.EntryPointAccessors
import kotlin.random.Random
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LargeLibrarySeedTest {
    @Test
    fun seedActiveProfile(): Unit = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val size = arguments.getString("largeLibrarySize")?.toInt()
        assumeTrue(size != null)
        val serverUrl = arguments.getString("largeLibraryServer") ?: "http://10.0.2.2:8765"
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val profiles = EntryPointAccessors.fromApplication(context, AndroidAutoDebugEntryPoint::class.java).profileCoordinator()
        profiles.initialize()
        val runtime = checkNotNull(profiles.activeRuntime.value).component

        runtime.connections().upsert(ProviderConnection(
            id = CONNECTION,
            source = BookSource.AUDIOBOOKSHELF,
            name = "Large library probe",
            serverUrl = serverUrl,
            username = "probe",
            urlScheme = UrlScheme.HTTP,
        ))
        runtime.vault().put(CredentialVault.accessTokenKey(CONNECTION), "large-library-probe-token")
        runtime.preferencesFacade().setPreferredStartTab(HearthStartTab.LIBRARY)

        val now = System.currentTimeMillis()
        val libraryId = "$CONNECTION::$LIBRARY"
        runtime.libraryCacheDao().upsert(listOf(CachedLibrary(libraryId, "Audiobooks", BookSource.AUDIOBOOKSHELF.name, CONNECTION, size!!, now)))
        val dao = runtime.bookCacheDao()
        (0 until size).asSequence().map { book(it, serverUrl, libraryId).toCachedBook(now) }.chunked(500).forEach { dao.replaceRows(it) }
        assertEquals(size, dao.countForConnection(CONNECTION))
    }

    private fun book(index: Int, serverUrl: String, libraryId: String): Book {
        val random = Random(index)
        val id = "li-%06d".format(index)
        return Book(
            id = id,
            title = words(random, random.nextInt(2, 7)),
            author = (1..if (random.nextFloat() < 0.85f) 1 else 2).joinToString { person(random.nextInt(8000)) },
            narrator = (1..if (random.nextFloat() < 0.8f) 1 else random.nextInt(2, 5)).joinToString { person(random.nextInt(1500) + 9000) },
            description = (1..random.nextInt(2, 6)).joinToString("", "<p>", "</p>") {
                (1..random.nextInt(2, 6)).joinToString(" ") { SENTENCES[random.nextInt(SENTENCES.size)] } + "</p><p>"
            },
            coverUrl = "$serverUrl/api/items/$id/cover",
            duration = random.nextLong(3_600, 180_000),
            source = BookSource.AUDIOBOOKSHELF,
            mediaType = AppMediaType.AUDIOBOOK,
            seriesName = if (random.nextFloat() < 0.6f) "The ${words(Random(random.nextInt(6000)), 2)} Saga" else null,
            seriesNumber = random.nextInt(1, 15).toString(),
            libraryId = libraryId,
            connectionId = CONNECTION,
            addedOn = 1_700_000_000_000L - index * 60_000L,
            hasAudio = true,
        )
    }

    private fun person(seed: Int): String = Random(seed).let { "${FIRST[it.nextInt(FIRST.size)]} ${LAST[it.nextInt(LAST.size)]}" }

    private fun words(random: Random, count: Int): String =
        (1..count).joinToString(" ") { WORDS[random.nextInt(WORDS.size)].replaceFirstChar(Char::uppercase) }

    private companion object {
        const val CONNECTION = "large-library-probe"
        const val LIBRARY = "lib-main"
        val WORDS = ("shadow river ember crown winter glass thorn hollow silver ash raven tide storm lantern orchard iron salt " +
            "ghost harbor mirror serpent throne garden clock paper wolf bone star empire quiet last first broken hidden " +
            "burning forgotten drowned golden crimson midnight northern wandering secret long dark bright").split(" ")
        val FIRST = "James Mary Robert Patricia John Jennifer Michael Linda David Elizabeth William Barbara Richard Susan Joseph Jessica Thomas Sarah Ursula Neil Octavia Brandon Naomi Terry Robin Kazuo Chimamanda Haruki".split(" ")
        val LAST = "Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez Martinez Hernandez Lopez Gonzalez Wilson Anderson Thomas Taylor Moore Jackson Martin Lee Perez Thompson White Sanderson Jemisin Pratchett Hobb Ishiguro Adichie Murakami".split(" ")
        val SENTENCES = listOf(
            "In a city where the tide keeps its own calendar, a reluctant archivist discovers a ledger that should not exist.",
            "What begins as a quiet inheritance becomes a pursuit across three countries and one unfinished war.",
            "Critics have called it a luminous, unsparing portrait of a family that refuses to forgive itself.",
            "The acclaimed narrator returns for this unabridged production, recorded in full over fourteen sessions.",
            "Winner of several major awards and a reader favourite for more than a decade.",
            "Nothing in the valley is what it seems, least of all the people who claim to remember its founding.",
            "This edition includes a new afterword by the author and a conversation with the performer.",
            "A sweeping story of loyalty, ambition and the price of keeping a promise made in childhood.",
        )
    }
}
