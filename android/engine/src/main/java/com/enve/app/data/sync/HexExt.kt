package com.enve.app.data.sync

internal fun ByteArray.toHexLower(): String =
    joinToString("") { "%02x".format(it) }
