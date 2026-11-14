package com.enve.app.cloud

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.enve.app.data.fileimport.CompletedFileImporter
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.profiles.ProfileLifecycleRegistry
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.app.viewmodel.ThemeViewModel
import com.enve.app.webimport.WebStoryImportScreen
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class WebStoryImportActivity : ComponentActivity() {
    @Inject lateinit var profileCoordinator: ProfileSwitchCoordinator
    @Inject lateinit var profileLifecycle: ProfileLifecycleRegistry
    private lateinit var profileBinding: ProfileActivityBinding
    private lateinit var importer: CompletedFileImporter

    private val themeViewModel: ThemeViewModel by viewModels { profileBinding.factory }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        profileBinding = ProfileActivityBinding.attach(this, profileCoordinator, profileLifecycle)
            ?: run { finish(); return }
        importer = profileBinding.runtime.component.completedFileImporter()
        enableEdgeToEdge()

        setContent {
            ImportActivityTheme(themeViewModel, profileBinding.runtime.component.preferencesFacade()) {
                WebStoryImportScreen(
                    onBack = { finish() },
                    onImport = { file ->
                        check(!profileBinding.retired) { "This profile is no longer open." }
                        importer.importFile(file)
                    },
                )
            }
        }
    }

    companion object {
        fun createIntent(context: Context): Intent = Intent(context, WebStoryImportActivity::class.java).apply {
            ProfileActivityBinding.capture(context, this)
        }
    }
}
