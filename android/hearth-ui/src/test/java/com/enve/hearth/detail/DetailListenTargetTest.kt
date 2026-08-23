package com.enve.hearth.detail

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertSame
import org.junit.Test

class DetailListenTargetTest {

    @Test
    fun storytellerReadAloudListensToItselfEvenWhenLinkedToAudiobookshelf() {
        val storyteller = Book(
            id = "storyteller",
            title = "Storyteller read-aloud",
            source = BookSource.STORYTELLER,
            mediaType = AppMediaType.EBOOK,
            hasAudio = true,
            hasEbook = true,
            readAlongAvailable = true,
        )
        val audiobookshelf = Book(
            id = "audiobookshelf",
            title = "Linked audiobook",
            source = BookSource.AUDIOBOOKSHELF,
            mediaType = AppMediaType.AUDIOBOOK,
        )

        assertSame(storyteller, detailListenTarget(storyteller, audiobookshelf))
    }

    @Test
    fun plainEbookListensToLinkedAudiobook() {
        val ebook = Book(
            id = "ebook",
            title = "Plain ebook",
            source = BookSource.STORYTELLER,
            mediaType = AppMediaType.EBOOK,
        )
        val audiobook = Book(
            id = "audiobook",
            title = "Linked audiobook",
            source = BookSource.AUDIOBOOKSHELF,
            mediaType = AppMediaType.AUDIOBOOK,
        )

        assertSame(audiobook, detailListenTarget(ebook, audiobook))
    }

    @Test
    fun storytellerReadAloudDoesNotFallBackWhenAudioFlagHasNotBeenHydrated() {
        val storyteller = Book(
            id = "storyteller",
            title = "Storyteller read-aloud",
            source = BookSource.STORYTELLER,
            mediaType = AppMediaType.EBOOK,
            hasAudio = false,
            hasEbook = true,
            readAlongAvailable = true,
        )
        val audiobookshelf = Book(
            id = "audiobookshelf",
            title = "Linked audiobook",
            source = BookSource.AUDIOBOOKSHELF,
            mediaType = AppMediaType.AUDIOBOOK,
        )

        assertSame(storyteller, detailListenTarget(storyteller, audiobookshelf))
    }
}
