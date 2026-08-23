package com.enve.core.data.local

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Entity(
    tableName = "user_collections",
    indices = [
        Index("name"),
        Index("updatedAt"),
    ],
)
data class UserCollection(
    @PrimaryKey val id: String,
    val name: String,
    val description: String?,
    val iconName: String,
    val colorHex: String,
    val createdAt: Long,
    val updatedAt: Long,
)

@Entity(
    tableName = "user_collection_books",
    primaryKeys = ["collectionId", "bookKey"],
    foreignKeys = [
        ForeignKey(
            entity = UserCollection::class,
            parentColumns = ["id"],
            childColumns = ["collectionId"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        Index("bookKey"),
        Index("addedAt"),
    ],
)
data class UserCollectionBook(
    val collectionId: String,
    val bookKey: String,
    val addedAt: Long,
)

data class UserCollectionSummary(
    val id: String,
    val name: String,
    val description: String?,
    val iconName: String,
    val colorHex: String,
    val createdAt: Long,
    val updatedAt: Long,
    val bookCount: Int,
)

data class UserCollectionMembership(
    val id: String,
    val name: String,
    val description: String?,
    val iconName: String,
    val colorHex: String,
    val createdAt: Long,
    val updatedAt: Long,
    val bookCount: Int,
    val containsBook: Boolean,
)

@Dao
interface UserCollectionDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertCollection(collection: UserCollection)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun addBook(membership: UserCollectionBook)

    @Query("DELETE FROM user_collection_books WHERE collectionId = :collectionId AND bookKey = :bookKey")
    suspend fun removeBook(collectionId: String, bookKey: String)

    @Query("""
        INSERT OR IGNORE INTO user_collection_books(collectionId, bookKey, addedAt)
        SELECT collectionId, :targetBookKey, addedAt
        FROM user_collection_books
        WHERE bookKey = :sourceBookKey
    """)
    suspend fun copyBookMemberships(sourceBookKey: String, targetBookKey: String)

    @Query("DELETE FROM user_collection_books WHERE bookKey = :bookKey")
    suspend fun removeBookFromAllCollections(bookKey: String)

    @Query("DELETE FROM user_collections WHERE id = :collectionId")
    suspend fun deleteCollection(collectionId: String)

    @Query("""
        SELECT c.id, c.name, c.description, c.iconName, c.colorHex, c.createdAt, c.updatedAt,
               COUNT(m.bookKey) AS bookCount
        FROM user_collections c
        LEFT JOIN user_collection_books m ON m.collectionId = c.id
        GROUP BY c.id
        ORDER BY c.updatedAt DESC, c.name COLLATE NOCASE
    """)
    fun observeSummaries(): Flow<List<UserCollectionSummary>>

    @Query("""
        SELECT c.id, c.name, c.description, c.iconName, c.colorHex, c.createdAt, c.updatedAt,
               COUNT(m.bookKey) AS bookCount
        FROM user_collections c
        LEFT JOIN user_collection_books m ON m.collectionId = c.id
        GROUP BY c.id
        ORDER BY c.updatedAt DESC, c.name COLLATE NOCASE
    """)
    suspend fun getSummaries(): List<UserCollectionSummary>

    @Query("""
        SELECT c.id, c.name, c.description, c.iconName, c.colorHex, c.createdAt, c.updatedAt,
               COUNT(allBooks.bookKey) AS bookCount,
               CASE WHEN COUNT(bookMatch.bookKey) > 0 THEN 1 ELSE 0 END AS containsBook
        FROM user_collections c
        LEFT JOIN user_collection_books allBooks ON allBooks.collectionId = c.id
        LEFT JOIN user_collection_books bookMatch
               ON bookMatch.collectionId = c.id AND bookMatch.bookKey = :bookKey
        GROUP BY c.id
        ORDER BY c.updatedAt DESC, c.name COLLATE NOCASE
    """)
    suspend fun getMembershipsForBook(bookKey: String): List<UserCollectionMembership>

    @Query("""
        SELECT b.*
        FROM book_cache b
        INNER JOIN user_collection_books m ON m.bookKey = b.cacheKey
        WHERE m.collectionId = :collectionId
        ORDER BY m.addedAt DESC
    """)
    suspend fun booksInCollection(collectionId: String): List<CachedBook>

    @Query("DELETE FROM user_collection_books")
    suspend fun clearMemberships()

    @Query("DELETE FROM user_collections")
    suspend fun clearCollections()
}
