package com.enve.app.playback

import com.enve.app.profiles.ProfileSwitchCoordinator
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface AndroidAutoDebugEntryPoint {
    fun profileCoordinator(): ProfileSwitchCoordinator
}
