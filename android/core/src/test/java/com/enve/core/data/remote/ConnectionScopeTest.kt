package com.enve.core.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ConnectionScopeTest {
    @Test
    fun withConnectionIdRestoresTheOuterScope() {
        ConnectionScope.withConnectionId("outer") {
            ConnectionScope.withConnectionId("inner") {
                assertEquals("inner", ConnectionScope.getConnectionId())
            }
            assertEquals("outer", ConnectionScope.getConnectionId())
            runCatching { ConnectionScope.withConnectionId("failing") { error("boom") } }
            assertEquals("outer", ConnectionScope.getConnectionId())
        }
        assertNull(ConnectionScope.getConnectionId())
    }

    @Test
    fun propagatingExecutorCarriesTheSubmittingScope() {
        val pool = Executors.newSingleThreadExecutor()
        val executor = ConnectionScope.propagatingExecutor(pool)
        var seen: String? = "unset"
        var after: String? = "unset"
        ConnectionScope.withConnectionId("submitter") {
            executor.execute { seen = ConnectionScope.getConnectionId() }
        }
        executor.execute { after = ConnectionScope.getConnectionId() }
        pool.shutdown()
        pool.awaitTermination(5, TimeUnit.SECONDS)
        assertEquals("submitter", seen)
        assertNull(after)
    }
}
