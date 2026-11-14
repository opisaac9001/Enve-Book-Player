package com.enve.app.cloud

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.enve.app.data.fileimport.DropboxLinkDownloader
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.profiles.ProfileLifecycleRegistry
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.app.viewmodel.ThemeViewModel
import dagger.hilt.android.AndroidEntryPoint
import java.io.File
import javax.inject.Inject

@AndroidEntryPoint
class CloudImportActivity : ComponentActivity() {
    @Inject lateinit var profileCoordinator: ProfileSwitchCoordinator
    @Inject lateinit var profileLifecycle: ProfileLifecycleRegistry
    private lateinit var profileBinding: ProfileActivityBinding
    private lateinit var service: CloudStorageService

    private val themeViewModel: ThemeViewModel by viewModels { profileBinding.factory }
    private val importViewModel: CloudImportViewModel by viewModels {
        viewModelFactory {
            initializer {
                val component = profileBinding.runtime.component
                CloudImportViewModel(
                    service = service,
                    resolver = contentResolver,
                    browser = CloudDocumentBrowser(contentResolver),
                    importer = component.completedFileImporter(),
                    linkDownloader = if (service == CloudStorageService.DROPBOX) {
                        DropboxLinkDownloader(File(component.storageLocations().cacheDirectory, "dropbox-links"))
                    } else {
                        null
                    },
                )
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        profileBinding = ProfileActivityBinding.attach(this, profileCoordinator, profileLifecycle)
            ?: run { finish(); return }
        service = intent.getStringExtra(EXTRA_SERVICE)
            ?.let { name -> CloudStorageService.entries.firstOrNull { it.name == name } }
            ?: run { finish(); return }
        enableEdgeToEdge()

        setContent {
            ImportActivityTheme(themeViewModel, profileBinding.runtime.component.preferencesFacade()) {
                val state by importViewModel.state.collectAsStateWithLifecycle()
                val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
                    importViewModel.onFilesPicked(uris)
                }
                val pickFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
                    importViewModel.onFolderPicked(uri)
                }
                BackHandler(enabled = state.progress == null && state.path.size > 1) { importViewModel.up() }
                CloudImportScreen(
                    state = state,
                    onBack = { if (!importViewModel.up()) finish() },
                    onChooseFiles = { pickFiles.launch(arrayOf("*/*")) },
                    onChooseFolder = { pickFolder.launch(null) },
                    onOpen = importViewModel::open,
                    onToggle = importViewModel::toggle,
                    onSelectAll = importViewModel::selectAllVisible,
                    onClearSelection = importViewModel::clearSelection,
                    onRefresh = importViewModel::refresh,
                    onGroupingChange = importViewModel::setGrouping,
                    onImport = importViewModel::startImport,
                    onCancelImport = importViewModel::cancelImport,
                    onImportLink = importViewModel::importDropboxLink,
                    onDismissMessage = importViewModel::dismissMessage,
                )
            }
        }
    }

    companion object {
        private const val EXTRA_SERVICE = "enve.cloud_service"

        fun createIntent(context: Context, service: CloudStorageService): Intent =
            Intent(context, CloudImportActivity::class.java).apply {
                ProfileActivityBinding.capture(context, this)
                putExtra(EXTRA_SERVICE, service.name)
            }
    }
}
