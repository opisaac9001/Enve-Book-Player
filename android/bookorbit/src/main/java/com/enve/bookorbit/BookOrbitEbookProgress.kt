package com.enve.bookorbit

import com.enve.core.reader.EpubBridgeCheckpointCodec

internal fun bookOrbitFoliateCfi(locator: String?): String? =
    EpubBridgeCheckpointCodec.foliateCfi(locator)
