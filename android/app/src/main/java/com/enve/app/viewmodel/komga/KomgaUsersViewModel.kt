package com.enve.app.viewmodel.komga

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.komga.dto.KomgaLibraryDto
import com.enve.komga.dto.KomgaSharedLibrariesUpdateDto
import com.enve.komga.dto.KomgaUserCreationDto
import com.enve.komga.dto.KomgaUserDto
import com.enve.komga.dto.KomgaUserUpdateDto
import com.enve.komga.KomgaRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class KomgaUsersState(
    val isLoading: Boolean = true,
    val users: List<KomgaUserDto> = emptyList(),
    val libraries: List<KomgaLibraryDto> = emptyList(),
    val error: String? = null,
    val toast: String? = null,
)

@HiltViewModel
class KomgaUsersViewModel @Inject constructor(
    private val repository: KomgaRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    val connectionId: String = savedStateHandle.get<String>("connectionId").orEmpty()

    private val _state = MutableStateFlow(KomgaUsersState())
    val state: StateFlow<KomgaUsersState> = _state.asStateFlow()

    init { refresh() }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            withKomgaConnection(connectionId) {
                val users = repository.adminListUsers().getOrNull().orEmpty()
                val libraries = repository.fetchLibrariesRaw().getOrNull().orEmpty()
                _state.update { it.copy(isLoading = false, users = users, libraries = libraries) }
            }
        }
    }

    fun consumeToast() = _state.update { it.copy(toast = null) }
    fun consumeError() = _state.update { it.copy(error = null) }

    fun createUser(email: String, password: String, isAdmin: Boolean) {
        if (email.isBlank() || password.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                val roles = if (isAdmin) listOf("ADMIN", "PAGE_STREAMING", "FILE_DOWNLOAD") else listOf("PAGE_STREAMING", "FILE_DOWNLOAD")
                repository.adminCreateUser(KomgaUserCreationDto(email, password, roles))
                    .onSuccess { _state.update { it.copy(toast = "User created") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun deleteUser(id: String) {
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminDeleteUser(id)
                    .onSuccess { _state.update { it.copy(toast = "User deleted") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun updateRoles(user: KomgaUserDto, isAdmin: Boolean, canDownload: Boolean, canStream: Boolean) {
        viewModelScope.launch {
            val roles = buildList {
                if (isAdmin) add("ADMIN")
                if (canDownload) add("FILE_DOWNLOAD")
                if (canStream) add("PAGE_STREAMING")
            }
            withKomgaConnection(connectionId) {
                repository.adminUpdateUser(user.id, KomgaUserUpdateDto(roles = roles))
                    .onSuccess { _state.update { it.copy(toast = "Roles updated") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun updateSharedLibraries(user: KomgaUserDto, all: Boolean, libraryIds: List<String>) {
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminUpdateUser(
                    user.id,
                    KomgaUserUpdateDto(sharedLibraries = KomgaSharedLibrariesUpdateDto(all, libraryIds))
                )
                    .onSuccess { _state.update { it.copy(toast = "Library access updated") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun changePassword(userId: String, password: String) {
        if (password.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminUpdateUserPassword(userId, password)
                    .onSuccess { _state.update { it.copy(toast = "Password changed") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
        }
    }
}
