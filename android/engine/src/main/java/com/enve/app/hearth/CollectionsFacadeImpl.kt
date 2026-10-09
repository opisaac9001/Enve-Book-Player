package com.enve.app.hearth

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import android.net.Uri
import com.enve.core.data.local.CustomSmartCollection
import com.enve.core.data.local.CustomSmartCollectionDao
import com.enve.core.data.local.SmartCollectionPolicy
import com.enve.core.data.local.ruleGroup
import com.enve.core.data.local.UserCollection
import com.enve.core.data.local.UserCollectionBook
import com.enve.core.data.local.UserCollectionDao
import com.enve.core.data.local.UserCollectionSummary
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.engine.collections.CollectionsFacade
import com.enve.engine.library.LibraryFacade
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID
import javax.inject.Inject

class CollectionsFacadeImpl @Inject constructor(
    @ApplicationContext private val context: Context,
    private val manualDao: UserCollectionDao,
    private val smartDao: CustomSmartCollectionDao,
    private val library: LibraryFacade,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) : CollectionsFacade {
    override val manualCollections: Flow<List<UserCollectionSummary>> = manualDao.observeSummaries()
    override val smartCollections: Flow<List<CustomSmartCollection>> = smartDao.observeAll().map {
        SmartCollectionPolicy.systemCollections + it
    }

    override suspend fun saveManualCollection(
        id: String?,
        name: String,
        description: String?,
        iconName: String,
        colorHex: String,
        coverUri: String?,
        removeCover: Boolean,
    ): String {
        val now = System.currentTimeMillis()
        val existing = id?.let { key -> manualDao.getSummaries().firstOrNull { it.id == key } }
        val key = id ?: UUID.randomUUID().toString()
        val newCover = coverUri?.let { copyCover(it) }
        try {
            manualDao.upsertCollection(UserCollection(
                id = key,
                name = name.trim(),
                description = description?.trim()?.takeIf(String::isNotEmpty),
                iconName = iconName,
                colorHex = colorHex,
                createdAt = existing?.createdAt ?: now,
                updatedAt = now,
                coverPath = newCover ?: existing?.coverPath?.takeUnless { removeCover },
            ))
        } catch (e: Exception) {
            newCover?.let { File(it).delete() }
            throw e
        }
        if (newCover != null || removeCover) existing?.coverPath?.let { File(it).delete() }
        return key
    }

    override suspend fun deleteManualCollection(id: String) {
        val cover = manualDao.getSummaries().firstOrNull { it.id == id }?.coverPath
        manualDao.deleteCollection(id)
        cover?.let { File(it).delete() }
    }

    override suspend fun booksInManualCollection(id: String): List<Book> =
        manualDao.booksInCollection(id).map { it.toBook() }

    override suspend fun setBookInManualCollection(id: String, book: Book, included: Boolean) {
        if (included) manualDao.addBook(UserCollectionBook(id, book.uniqueKey, System.currentTimeMillis()))
        else manualDao.removeBook(id, book.uniqueKey)
    }

    override suspend fun saveSmartCollection(collection: CustomSmartCollection, coverUri: String?, removeCover: Boolean) {
        require(!collection.id.startsWith("system-"))
        val oldCover = smartDao.get(collection.id)?.coverPath
        val newCover = coverUri?.let { copyCover(it) }
        try {
            smartDao.upsert(collection.copy(
                name = collection.name.trim(),
                updatedAt = System.currentTimeMillis(),
                coverPath = newCover ?: oldCover?.takeUnless { removeCover },
            ))
        } catch (e: Exception) {
            newCover?.let { File(it).delete() }
            throw e
        }
        if (newCover != null || removeCover) oldCover?.let { File(it).delete() }
    }

    override suspend fun deleteSmartCollection(id: String) {
        require(!id.startsWith("system-"))
        val cover = smartDao.get(id)?.coverPath
        smartDao.delete(id)
        cover?.let { File(it).delete() }
    }

    override suspend fun booksInSmartCollection(collection: CustomSmartCollection): List<Book> {
        val books = library.allBooks.first()
        return if (collection.rulesJson == null) books.filter { SmartCollectionPolicy.matches(collection, it) }
        else collection.ruleGroup().let { group -> books.filter { SmartCollectionPolicy.matches(group, it) } }
    }

    private suspend fun copyCover(uriString: String): String = withContext(Dispatchers.IO) {
        val uri = Uri.parse(uriString)
        require(context.contentResolver.getType(uri)?.startsWith("image/") == true)
        val directory = File(locations.filesDirectory, "collection_covers").apply(File::mkdirs)
        val file = File(directory, "${UUID.randomUUID()}.image")
        try {
            context.contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input)
                file.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > 12_000_000L) throw IOException("Cover image is larger than 12 MB")
                        output.write(buffer, 0, read)
                    }
                }
            }
            file.absolutePath
        } catch (e: Exception) {
            file.delete()
            throw e
        }
    }
}
