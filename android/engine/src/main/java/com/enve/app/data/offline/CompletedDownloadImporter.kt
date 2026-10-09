package com.enve.app.data.offline

import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.FamilyProfile
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal data class CompletedDownloadFile(
    val source: File,
    val destinationName: String,
    val expectedBytes: Long = 0L,
)

internal object CompletedDownloadImporter {
    private const val RECEIPT_FILE = ".import-receipt.json"
    private val json = Json { encodeDefaults = true }

    @Serializable
    private data class Receipt(val sourceDigest: String, val localId: String)

    @Serializable
    private data class Grant(
        val profileId: String,
        val bookDigest: String,
        val format: String,
        val relativePath: String,
    )

    @Serializable
    private data class AssetRecord(
        val assetId: String,
        val bytes: Long,
        val device: Long,
        val inode: Long,
        val original: Grant,
        val adoptionPending: Boolean,
        val grants: List<Grant>,
    )

    @Synchronized
    fun recover(shared: File) {
        prepare(shared)
        records(shared).filter { it.adoptionPending }.forEach { record ->
            val original = grantFile(shared, record.original)
            val blob = blobFile(shared, record.assetId)
            if (!Files.exists(blob.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                validateRegular(original, record.bytes, record.device, record.inode)
                Files.move(original.toPath(), blob.toPath(), StandardCopyOption.ATOMIC_MOVE)
            }
            validateRegular(blob, record.bytes, record.device, record.inode)
            if (!Files.exists(original.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                check(original.parentFile!!.isDirectory || original.parentFile!!.mkdirs())
                Files.createSymbolicLink(original.toPath(), blob.absoluteFile.toPath())
            } else {
                check(Files.isSymbolicLink(original.toPath()) && original.canonicalFile == blob.canonicalFile)
            }
            syncDirectory(blob.parentFile!!)
            syncDirectory(original.parentFile!!)
            save(shared, record.copy(adoptionPending = false))
        }
    }

    @Synchronized
    fun resolve(shared: File, profileId: String, format: String, root: File, file: File): File {
        val expectedRoot = rootFor(shared, profileId, format)
        require(root.absoluteFile == expectedRoot.absoluteFile)
        val candidate = contained(shared.parentFile!!, expectedRoot, file)
        if (!Files.isSymbolicLink(candidate.toPath())) return candidate.canonicalFile
        val relative = candidate.relativeTo(expectedRoot).invariantSeparatorsPath
        val target = Files.readSymbolicLink(candidate.toPath())
        val record = records(shared).firstOrNull { record ->
            record.grants.any { it.profileId == profileId && it.format == format && it.relativePath == relative } &&
                target == blobFile(shared, record.assetId).absoluteFile.toPath()
        }
        requireNotNull(record)
        val blob = blobFile(shared, record.assetId)
        validateRegular(blob, record.bytes, record.device, record.inode)
        return blob.canonicalFile
    }

    @Synchronized
    fun revoke(shared: File, profileId: String, bookId: String, format: String) {
        recover(shared)
        val bookDigest = digest(bookId)
        records(shared).forEach { record ->
            val retained = record.grants.filterNot {
                it.profileId == profileId && it.bookDigest == bookDigest && it.format == format
            }
            if (retained.size != record.grants.size) save(shared, record.copy(grants = retained))
        }
    }

    @Synchronized
    fun collectUnused(shared: File): Long {
        recover(shared)
        var reclaimed = 0L
        records(shared).forEach { record ->
            val blob = blobFile(shared, record.assetId)
            val grants = record.grants.filter { grant ->
                val file = grantFile(shared, grant)
                Files.isSymbolicLink(file.toPath()) && Files.readSymbolicLink(file.toPath()) == blob.absoluteFile.toPath()
            }
            if (grants.isEmpty()) {
                if (Files.exists(blob.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                    validateRegular(blob, record.bytes, record.device, record.inode)
                    Files.delete(blob.toPath())
                    reclaimed += record.bytes
                }
                AtomicFile(File(shared, "records/${record.assetId}.json")).delete()
            } else {
                validateRegular(blob, record.bytes, record.device, record.inode)
                if (grants != record.grants) save(shared, record.copy(grants = grants))
            }
        }
        syncDirectory(File(shared, "assets"))
        syncDirectory(File(shared, "records"))
        return reclaimed
    }

    @Synchronized
    fun physicalBytes(shared: File): Long {
        recover(shared)
        return records(shared).sumOf { record ->
            val blob = blobFile(shared, record.assetId)
            validateRegular(blob, record.bytes, record.device, record.inode)
            record.bytes
        }
    }

    @Synchronized
    fun findImported(shared: File, root: File, profileId: String, sourceProfileId: String, sourceBookId: String, format: String): File? {
        require(root.absoluteFile == rootFor(shared, profileId, format).absoluteFile)
        val sourceDigest = digest(json.encodeToString(listOf(sourceProfileId, sourceBookId, format)))
        return root.listFiles().orEmpty().filter { it.isDirectory && !it.name.startsWith(".") }
            .firstOrNull { directory ->
                val receiptFile = File(directory, RECEIPT_FILE)
                if (!receiptFile.exists()) return@firstOrNull false
                contained(shared.parentFile!!, root, receiptFile)
                require(!Files.isSymbolicLink(directory.toPath()) && !Files.isSymbolicLink(receiptFile.toPath()))
                val receipt = json.decodeFromString<Receipt>(receiptFile.readText())
                check(receipt.localId == directory.name)
                receipt.sourceDigest == sourceDigest
            }
    }

    @Synchronized
    fun importCompleted(
        shared: File,
        sourceRoot: File,
        sourceProfileId: String,
        sourceBookId: String,
        format: String,
        destinationRoot: File,
        destinationProfileId: String,
        files: List<CompletedDownloadFile>,
        beforePublish: () -> Unit = {},
        writeManifest: (localId: String, stage: File) -> Unit,
    ): File {
        recover(shared)
        require(files.isNotEmpty())
        require(files.map { it.destinationName }.distinct().size == files.size)
        require(sourceProfileId != destinationProfileId)
        require(sourceRoot.absoluteFile == rootFor(shared, sourceProfileId, format).absoluteFile)
        require(destinationRoot.absoluteFile == rootFor(shared, destinationProfileId, format).absoluteFile)
        contained(shared.parentFile!!, destinationRoot, destinationRoot)
        val sourceDigest = digest(json.encodeToString(listOf(sourceProfileId, sourceBookId, format)))
        val existing = findImported(shared, destinationRoot, destinationProfileId, sourceProfileId, sourceBookId, format)
        if (existing != null) return existing

        val localId = "local-import-${UUID.randomUUID()}"
        val stage = File(destinationRoot, ".import-${UUID.randomUUID()}")
        check(stage.mkdir())
        try {
            files.forEach { payload ->
                require(payload.destinationName.matches(Regex("[a-zA-Z0-9_-]+\\.[a-zA-Z0-9]+")))
                require(payload.expectedBytes >= 0L)
                val sourceFile = contained(shared.parentFile!!, sourceRoot, payload.source)
                val resolved = resolve(shared, sourceProfileId, format, sourceRoot, sourceFile)
                val asset = if (Files.isSymbolicLink(sourceFile.toPath())) {
                    records(shared).single { blobFile(shared, it.assetId).canonicalFile == resolved }
                } else {
                    adopt(shared, sourceFile, sourceProfileId, sourceBookId, format, payload.expectedBytes)
                }
                require(payload.expectedBytes == 0L || payload.expectedBytes == asset.bytes)
                val grant = Grant(destinationProfileId, digest(localId), format, "$localId/${payload.destinationName}")
                save(shared, asset.copy(grants = (asset.grants + grant).distinct()))
                Files.createSymbolicLink(File(stage, payload.destinationName).toPath(), blobFile(shared, asset.assetId).absoluteFile.toPath())
            }
            writeManifest(localId, stage)
            File(stage, RECEIPT_FILE).writeText(json.encodeToString(Receipt(sourceDigest, localId)))
            val destination = File(destinationRoot, localId)
            check(!Files.exists(destination.toPath(), LinkOption.NOFOLLOW_LINKS))
            beforePublish()
            Files.move(stage.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            syncDirectory(destinationRoot)
            return destination
        } catch (failure: Exception) {
            revoke(shared, destinationProfileId, localId, format)
            throw failure
        } finally {
            if (stage.exists()) stage.deleteRecursively()
        }
    }

    private fun adopt(shared: File, source: File, profileId: String, bookId: String, format: String, expectedBytes: Long): AssetRecord {
        val descriptor = Os.open(source.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        try {
            val pinned = Os.fstat(descriptor)
            require(OsConstants.S_ISREG(pinned.st_mode) && pinned.st_size > 0L)
            require(expectedBytes == 0L || expectedBytes == pinned.st_size)
            val grant = Grant(profileId, digest(bookId), format, source.relativeTo(rootFor(shared, profileId, format)).invariantSeparatorsPath)
            val record = AssetRecord(UUID.randomUUID().toString(), pinned.st_size, pinned.st_dev, pinned.st_ino, grant, true, listOf(grant))
            save(shared, record)
            val blob = blobFile(shared, record.assetId)
            Files.move(source.toPath(), blob.toPath(), StandardCopyOption.ATOMIC_MOVE)
            validateRegular(blob, pinned.st_size, pinned.st_dev, pinned.st_ino)
            Files.createSymbolicLink(source.toPath(), blob.absoluteFile.toPath())
            syncDirectory(blob.parentFile!!)
            syncDirectory(source.parentFile!!)
            val adopted = record.copy(adoptionPending = false)
            save(shared, adopted)
            return adopted
        } finally {
            Os.close(descriptor)
        }
    }

    private fun contained(deviceFiles: File, root: File, file: File): File {
        val rootPath = root.absoluteFile.toPath().normalize()
        val path = file.absoluteFile.toPath().normalize()
        require(file.absoluteFile.toPath() == path && path.startsWith(rootPath))
        require(!Files.isSymbolicLink(rootPath))
        val devicePath = deviceFiles.absoluteFile.toPath().normalize()
        require(rootPath.startsWith(devicePath))
        var current = devicePath
        for (segment in devicePath.relativize(path.parent)) {
            current = current.resolve(segment)
            require(!Files.isSymbolicLink(current))
        }
        return path.toFile()
    }

    private fun rootFor(shared: File, profileId: String, format: String): File {
        require(FamilyProfile.validId(profileId))
        val files = if (profileId == DEFAULT_ADULT_PROFILE_ID) shared.parentFile!! else File(shared.parentFile, "profiles/$profileId")
        return File(files, when (format) {
            "audio" -> "offline-audio"
            "ebook" -> "offline-comics"
            else -> error("Unsupported download format")
        })
    }

    private fun grantFile(shared: File, grant: Grant): File =
        contained(shared.parentFile!!, rootFor(shared, grant.profileId, grant.format), File(rootFor(shared, grant.profileId, grant.format), grant.relativePath))

    private fun blobFile(shared: File, assetId: String): File {
        require(UUID.fromString(assetId).toString() == assetId)
        require(!Files.isSymbolicLink(shared.toPath()) && !Files.isSymbolicLink(File(shared, "assets").toPath()))
        return File(shared, "assets/$assetId.bin")
    }

    private fun validateRegular(file: File, bytes: Long, device: Long, inode: Long) {
        val stat = Os.lstat(file.path)
        require(OsConstants.S_ISREG(stat.st_mode) && bytes > 0L && stat.st_size == bytes)
        require(stat.st_dev == device && stat.st_ino == inode)
    }

    private fun prepare(shared: File) {
        for (directory in listOf(shared, File(shared, "assets"), File(shared, "records"))) {
            require(!Files.isSymbolicLink(directory.toPath()))
            check(directory.isDirectory || directory.mkdirs())
        }
    }

    private fun records(shared: File): List<AssetRecord> =
        File(shared, "records").listFiles().orEmpty().filter { it.extension == "json" }.map { file ->
            require(!Files.isSymbolicLink(file.toPath()))
            val record = AtomicFile(file).openRead().bufferedReader().use { json.decodeFromString<AssetRecord>(it.readText()) }
            check(file.nameWithoutExtension == record.assetId)
            blobFile(shared, record.assetId)
            record.grants.forEach { grantFile(shared, it) }
            record
        }

    private fun save(shared: File, record: AssetRecord) {
        val atomic = AtomicFile(File(shared, "records/${record.assetId}.json"))
        val output = atomic.startWrite()
        try {
            output.write(json.encodeToString(record).toByteArray())
            atomic.finishWrite(output)
        } catch (failure: Exception) {
            atomic.failWrite(output)
            throw failure
        }
        syncDirectory(File(shared, "records"))
    }

    private fun syncDirectory(file: File) {
        val directory = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try {
            check(OsConstants.S_ISDIR(Os.fstat(directory).st_mode))
            Os.fsync(directory)
        } finally {
            Os.close(directory)
        }
    }

    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}
