package com.enve.hearth.shell

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel

val LocalProfileViewModelFactory = staticCompositionLocalOf<ViewModelProvider.Factory> {
    error("A profile ViewModel factory is required")
}

@Composable
inline fun <reified VM : ViewModel> profileViewModel(): VM =
    viewModel(factory = LocalProfileViewModelFactory.current)
