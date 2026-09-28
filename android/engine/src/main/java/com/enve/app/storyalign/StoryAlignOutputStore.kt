package com.enve.app.storyalign

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class StoryAlignOutputStore internal constructor(private val outputDir: File) {

    @Inject
    constructor(@ApplicationContext context: Context) : this(File(context.filesDir, "storyalign/output"))

    fun acceptedFile(jobId: String): File = outputFile(jobId, "")

    fun previousFile(jobId: String): File = outputFile(jobId, ".previous")

    fun candidateFile(jobId: String): File = outputFile(jobId, ".candidate")

    private fun swapFile(jobId: String): File = outputFile(jobId, ".swap")

    private fun outputFile(jobId: String, stage: String): File =
        File(outputDir, "${jobId}_readaloud$stage.epub")

    fun prepareCandidate(jobId: String): File {
        outputDir.mkdirs()
        return candidateFile(jobId).apply { delete() }
    }

    @Synchronized
    fun promoteCandidate(jobId: String): File {
        val accepted = acceptedFile(jobId)
        val previous = previousFile(jobId)
        val candidate = candidateFile(jobId)
        check(candidate.isFile && candidate.length() > 0) { "No complete read-aloud candidate is available" }
        val swap = swapFile(jobId)
        check(!swap.exists() || swap.delete()) { "Could not clear the output staging file" }
        val hadAccepted = accepted.exists()
        if (hadAccepted) {
            check(accepted.renameTo(swap)) { "Could not retain the accepted read-aloud output" }
        }
        if (!candidate.renameTo(accepted)) {
            if (hadAccepted) check(swap.renameTo(accepted)) { "Could not recover the accepted read-aloud output" }
            error("Could not install the new read-aloud output")
        }
        if (hadAccepted) {
            if ((!previous.exists() || previous.delete()) && swap.renameTo(previous)) return accepted
            accepted.delete()
            check(swap.renameTo(accepted)) { "Could not recover the accepted read-aloud output" }
            error("Could not retain the previous read-aloud output")
        }
        return accepted
    }

    fun discardCandidate(jobId: String) {
        candidateFile(jobId).delete()
    }

    @Synchronized
    fun restorePrevious(jobId: String): File? {
        val accepted = acceptedFile(jobId)
        val previous = previousFile(jobId)
        if (!previous.exists()) return null

        val swap = swapFile(jobId)
        swap.delete()
        if (accepted.exists()) {
            check(accepted.renameTo(swap)) { "Could not set aside the current read-aloud output" }
        }
        if (!previous.renameTo(accepted)) {
            if (swap.exists()) check(swap.renameTo(accepted)) { "Could not recover the accepted output" }
            error("Could not restore the previous read-aloud output")
        }
        if (swap.exists()) {
            check(swap.renameTo(previous)) { "Could not retain the replaced read-aloud output" }
        }
        return accepted
    }

    fun deleteAll(jobId: String) {
        acceptedFile(jobId).delete()
        previousFile(jobId).delete()
        candidateFile(jobId).delete()
        swapFile(jobId).delete()
    }
}
