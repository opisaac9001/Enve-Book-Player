package com.enve.app.viewmodel.komga

import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.withContext

suspend inline fun <T> withKomgaConnection(connectionId: String, crossinline block: suspend () -> T): T =
    withContext(ConnectionScope.asContextElement(connectionId)) { block() }
