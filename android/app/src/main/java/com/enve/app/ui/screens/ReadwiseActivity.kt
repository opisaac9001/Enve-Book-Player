package com.enve.app.ui.screens

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.CompositionLocalProvider
import com.enve.app.cloud.ImportActivityTheme
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.profiles.ProfileLifecycleRegistry
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.app.viewmodel.ThemeViewModel
import com.enve.engine.readwise.ReadwiseExportScope
import com.enve.hearth.readwise.HearthReadwiseScreen
import com.enve.hearth.shell.LocalProfileViewModelFactory
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class ReadwiseActivity : ComponentActivity() {
    @Inject lateinit var profiles: ProfileSwitchCoordinator
    @Inject lateinit var lifecycleRegistry: ProfileLifecycleRegistry
    private lateinit var binding: ProfileActivityBinding
    private val theme: ThemeViewModel by viewModels { binding.factory }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ProfileActivityBinding.attach(this, profiles, lifecycleRegistry)
            ?: run { finish(); return }
        val bookId = intent.getStringExtra(EXTRA_BOOK_ID)?.takeIf(String::isNotBlank)
            ?: run { finish(); return }
        val connectionId = intent.getStringExtra(EXTRA_CONNECTION_ID)
        enableEdgeToEdge()
        setContent {
            CompositionLocalProvider(LocalProfileViewModelFactory provides binding.factory) {
                ImportActivityTheme(theme, binding.runtime.component.preferencesFacade()) {
                    HearthReadwiseScreen(scope = ReadwiseExportScope.Book(bookId, connectionId), onBack = ::finish)
                }
            }
        }
    }

    companion object {
        private const val EXTRA_BOOK_ID = "readwise_book_id"
        private const val EXTRA_CONNECTION_ID = "readwise_connection_id"

        fun createIntent(context: Context, bookId: String, connectionId: String?): Intent = Intent(context, ReadwiseActivity::class.java).apply {
            ProfileActivityBinding.capture(context, this)
            putExtra(EXTRA_BOOK_ID, bookId)
            putExtra(EXTRA_CONNECTION_ID, connectionId)
        }
    }
}
