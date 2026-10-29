package com.enve.app.data.local

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.content.Context
import com.enve.core.data.local.DeviceAnnouncementStore
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceAnnouncementStoreTest {
    @Test fun dismissalSurvivesRecreationAndAppliesToNewProfiles() = runBlocking {
        val file = File(ApplicationProvider.getApplicationContext<Context>().cacheDir, "announcement-${UUID.randomUUID()}.preferences_pb")
        var job = SupervisorJob()
        try {
            var data = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
            assertTrue(DeviceAnnouncementStore(data).shouldShowDiscord(0))
            DeviceAnnouncementStore(data).dismissDiscord()
            job.cancelAndJoin()
            job = SupervisorJob()
            data = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
            assertFalse(DeviceAnnouncementStore(data).shouldShowDiscord(0))
            assertFalse(DeviceAnnouncementStore(data).shouldShowDiscord(99999))
        } finally { job.cancelAndJoin(); file.delete() }
    }

    @Test fun migratesPriorOwnerAndProfileDismissals() = runBlocking {
        for (owner in listOf(false, true)) {
            val file = File(ApplicationProvider.getApplicationContext<Context>().cacheDir, "announcement-${UUID.randomUUID()}.preferences_pb")
            val job = SupervisorJob()
            try {
                val data = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
                if (owner) data.edit { it[intPreferencesKey("enve.lastAnnouncementSeen")] = 1 }
                assertFalse(DeviceAnnouncementStore(data).shouldShowDiscord(if (owner) 0 else 1))
                assertFalse(DeviceAnnouncementStore(data).shouldShowDiscord(0))
            } finally { job.cancelAndJoin(); file.delete() }
        }
    }
}
