package com.enve.app.di

import android.content.Context
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.di.ApplicationScope
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object OwnerStorageModule {
    @Provides
    @Singleton
    fun provideStorageLocations(@ApplicationContext context: Context): ProfileStorageLocations =
        ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID)

    @Provides
    @Singleton
    @ApplicationScope
    fun provideApplicationScope(): CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Provides
    @Singleton
    fun provideCredentialVault(@ApplicationContext context: Context): CredentialVault {
        return CredentialVault(context)
    }

    @Provides
    @Singleton
    fun providePreferencesManager(
        @ApplicationContext context: Context,
        vault: CredentialVault,
    ): PreferencesManager {
        return PreferencesManager(context, vault)
    }

    @Provides
    @Singleton
    fun provideReaderDatabase(@ApplicationContext context: Context): com.enve.app.data.local.ReaderDatabase {
        return com.enve.app.data.local.ReaderDatabase.getInstance(context)
    }

}
