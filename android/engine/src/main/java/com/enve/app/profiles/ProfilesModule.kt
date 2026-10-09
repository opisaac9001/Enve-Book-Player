package com.enve.app.profiles

import com.enve.engine.profiles.ProfilesFacade
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class ProfilesModule {
    @Binds
    @Singleton
    abstract fun profiles(coordinator: ProfileSwitchCoordinator): ProfilesFacade
}
