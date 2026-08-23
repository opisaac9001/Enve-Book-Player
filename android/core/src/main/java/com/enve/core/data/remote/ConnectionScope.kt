package com.enve.core.data.remote

import kotlinx.coroutines.asContextElement
import java.util.concurrent.ExecutorService

object ConnectionScope {
    private val currentConnectionId = ThreadLocal<String?>()

    fun getConnectionId(): String? = currentConnectionId.get()

    fun asContextElement(connectionId: String?) = currentConnectionId.asContextElement(connectionId)

    fun propagatingExecutor(delegate: ExecutorService): ExecutorService =
        object : ExecutorService by delegate {
            override fun execute(command: Runnable) {
                val captured = currentConnectionId.get()
                delegate.execute {
                    val previous = currentConnectionId.get()
                    currentConnectionId.set(captured)
                    try {
                        command.run()
                    } finally {
                        currentConnectionId.set(previous)
                    }
                }
            }
        }
}
