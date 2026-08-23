package com.enve.app.storyalign.transcribe

internal class WhisperLib {
    companion object {
        @Volatile private var loaded = false

        fun ensureLoaded() {
            if (!loaded) {
                System.loadLibrary("whisper")
                loaded = true
            }
        }

        external fun initContext(modelPath: String): Long
        external fun freeContext(ptr: Long)
        external fun fullTranscribe(ptr: Long, numThreads: Int, language: String, audioData: FloatArray): Int
        external fun getSegmentCount(ptr: Long): Int
        external fun getSegmentText(ptr: Long, i: Int): String
        external fun getSegmentT0(ptr: Long, i: Int): Long
        external fun getSegmentT1(ptr: Long, i: Int): Long
        external fun getTokenCount(ptr: Long, seg: Int): Int
        external fun getTokenText(ptr: Long, seg: Int, tok: Int): String
        external fun getTokenT0(ptr: Long, seg: Int, tok: Int): Long
        external fun getTokenT1(ptr: Long, seg: Int, tok: Int): Long
        external fun getTokenP(ptr: Long, seg: Int, tok: Int): Float
    }
}

class WhisperContext private constructor(private var ptr: Long) {

    fun transcribe(pcm16kMono: FloatArray, language: String, threads: Int): Int =
        WhisperLib.fullTranscribe(ptr, threads, language, pcm16kMono)

    fun segmentCount(): Int = WhisperLib.getSegmentCount(ptr)
    fun segmentText(i: Int): String = WhisperLib.getSegmentText(ptr, i)

    fun segmentStartSec(i: Int): Double = WhisperLib.getSegmentT0(ptr, i) / 100.0
    fun segmentEndSec(i: Int): Double = WhisperLib.getSegmentT1(ptr, i) / 100.0
    fun tokenCount(seg: Int): Int = WhisperLib.getTokenCount(ptr, seg)
    fun tokenText(seg: Int, tok: Int): String = WhisperLib.getTokenText(ptr, seg, tok)
    fun tokenStartSec(seg: Int, tok: Int): Double = WhisperLib.getTokenT0(ptr, seg, tok) / 100.0
    fun tokenEndSec(seg: Int, tok: Int): Double = WhisperLib.getTokenT1(ptr, seg, tok) / 100.0

    fun release() {
        if (ptr != 0L) {
            WhisperLib.freeContext(ptr)
            ptr = 0L
        }
    }

    companion object {
        fun fromFile(modelPath: String): WhisperContext {
            WhisperLib.ensureLoaded()
            val ptr = WhisperLib.initContext(modelPath)
            if (ptr == 0L) throw IllegalStateException("Failed to load whisper model: $modelPath")
            return WhisperContext(ptr)
        }
    }
}
