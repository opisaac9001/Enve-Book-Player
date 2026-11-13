package com.enve.app.data.opds

import androidx.security.crypto.MasterKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.KeyStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OpdsAuthStoreRecoveryTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun storeRestoredWithoutItsKeystoreKeyStartsEmpty() {
        OpdsAuthStore(context).save("opds", OpdsAuthSession(OpdsAuthenticationFlow.BASIC, username = "reader", password = "secret"))
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS)

        val reopened = OpdsAuthStore(context)

        assertNull(reopened.session("opds"))
        reopened.save("opds", OpdsAuthSession(OpdsAuthenticationFlow.BASIC, username = "again"))
        assertEquals("again", OpdsAuthStore(context).session("opds")?.username)
    }
}
