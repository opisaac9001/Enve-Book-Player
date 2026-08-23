package com.enve.app.data.sync

import java.security.MessageDigest

fun md5Hash(input: String): String =
    MessageDigest.getInstance("MD5").digest(input.toByteArray(Charsets.UTF_8)).toHexLower()
