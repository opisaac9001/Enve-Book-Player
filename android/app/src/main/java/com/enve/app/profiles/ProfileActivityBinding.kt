package com.enve.app.profiles

import android.content.Context
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch

class ProfileActivityBinding private constructor(
    val runtime: ActiveProfileRuntime,
    private val activity: ComponentActivity,
    lifecycle: ProfileLifecycleRegistry,
    private val coordinator: ProfileSwitchCoordinator,
    private val checkpoint: suspend () -> Unit,
) : DefaultLifecycleObserver {
    val factory = ProfileViewModelFactory(runtime.component)
    var retired = false
        private set
    private val registration = lifecycle.register(runtime.profileId) { retire() }

    private suspend fun retire() = withContext(Dispatchers.Main.immediate) {
        if (retired) return@withContext
        retired = true
        activity.window.decorView.visibility = android.view.View.INVISIBLE
        activity.lifecycleScope.coroutineContext[Job]?.children?.toList()?.forEach { it.cancelAndJoin() }
        checkpoint()
        activity.viewModelStore.clear()
        factory.retire()
        activity.finish()
    }

    override fun onStart(owner: LifecycleOwner) {
        if (coordinator.state.value.locked || coordinator.activeRuntime.value?.generation != runtime.generation) {
            activity.window.decorView.visibility = android.view.View.INVISIBLE
            runtime.component.resources().scope.launch { retire() }
        }
    }

    override fun onDestroy(owner: LifecycleOwner) {
        registration.close()
    }

    companion object {
        const val EXTRA_PROFILE_ID = "enve.profile_id"
        const val EXTRA_GENERATION = "enve.profile_generation"

        fun capture(context: Context, intent: Intent) {
            val coordinator = EntryPointAccessors.fromApplication(context.applicationContext, DeviceEntryPoint::class.java).profiles()
            val runtime = checkNotNull(coordinator.activeRuntime.value) { "Open a profile before continuing." }
            check(!coordinator.state.value.locked && !coordinator.state.value.switching) { "Unlock a profile before continuing." }
            intent.putExtra(EXTRA_PROFILE_ID, runtime.profileId)
            intent.putExtra(EXTRA_GENERATION, runtime.generation)
        }

        fun attach(
            activity: ComponentActivity,
            coordinator: ProfileSwitchCoordinator,
            lifecycle: ProfileLifecycleRegistry,
            checkpoint: suspend () -> Unit = {},
        ): ProfileActivityBinding? {
            val runtime = coordinator.activeRuntime.value ?: return null
            val id = activity.intent.getStringExtra(EXTRA_PROFILE_ID)
            val legacyOwner = !coordinator.state.value.enabled && runtime.profileId == DEFAULT_ADULT_PROFILE_ID && id == null
            if (coordinator.state.value.locked || coordinator.state.value.switching) return null
            if (!legacyOwner && (id != runtime.profileId || activity.intent.getLongExtra(EXTRA_GENERATION, -1L) != runtime.generation)) return null
            return ProfileActivityBinding(runtime, activity, lifecycle, coordinator, checkpoint).also { activity.lifecycle.addObserver(it) }
        }
    }

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface DeviceEntryPoint {
        fun profiles(): ProfileSwitchCoordinator
    }
}
