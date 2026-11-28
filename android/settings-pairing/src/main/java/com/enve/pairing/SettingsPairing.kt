package com.enve.pairing

import java.io.Closeable
import java.io.IOException

class SettingsPairing(code: String, sender: Boolean) : Closeable {
    private var handle = create(code.encodeToByteArray(), sender)
        .also { if (it == 0L) throw IOException("Invalid pairing code") }

    fun message(round: Int): ByteArray = write(activeHandle(), round) ?: throw IOException("Could not pair devices")

    fun accept(round: Int, message: ByteArray) {
        if (!read(activeHandle(), round, message)) throw IOException("Could not pair devices")
    }

    fun secret(): ByteArray = derive(activeHandle()) ?: throw IOException("Could not pair devices")

    override fun close() {
        if (handle == 0L) return
        destroy(handle)
        handle = 0
    }

    private fun activeHandle() = handle.also { check(it != 0L) }

    private external fun create(code: ByteArray, sender: Boolean): Long
    private external fun write(handle: Long, round: Int): ByteArray?
    private external fun read(handle: Long, round: Int, message: ByteArray): Boolean
    private external fun derive(handle: Long): ByteArray?
    private external fun destroy(handle: Long)

    companion object {
        init { System.loadLibrary("enve_settings_pairing") }
    }
}
