import Foundation
import Logging
import SwiftUI

class EmbyService {
    static let shared = EmbyService()
    private init() {}

    func authenticate(serverUrl: String, username: String, password: String) async throws {
        let normalizedURL = EmbyProvider.normalizeServerURL(serverUrl)
        try await EmbyProvider.shared.authenticate(serverURL: normalizedURL, username: username, password: password)
        AppLogger.network.info("[EmbyService] Authentication successful")
    }

    func validateToken(backend: BackendConfig) async throws -> Bool {
        let connection = ServerConnection(
            name: backend.name,
            url: backend.url,
            type: .emby
        )
        var mutableConnection = connection
        mutableConnection.token = backend.token
        mutableConnection.userId = backend.username

        let provider = EmbyProvider(connection: mutableConnection)
        return try await provider.validateConnection()
    }

    struct EmbyUser {
        let Id: String
        let Name: String?
    }

    func getCurrentUser(backend: BackendConfig) async throws -> EmbyUser {
        if let userId = backend.userId, !userId.isEmpty {
            return EmbyUser(Id: userId, Name: backend.name)
        }

        if let userId = EmbyProvider.shared.connection.userId, !userId.isEmpty {
            return EmbyUser(Id: userId, Name: backend.name)
        }
        throw ProviderError.unauthorized
    }

    func getLibraries(backend: BackendConfig, userId: String) async throws -> [LibraryMetadata] {
        let connection = ServerConnection(
            name: backend.name,
            url: backend.url,
            type: .emby
        )
        var mutableConnection = connection
        mutableConnection.token = backend.token
        mutableConnection.userId = userId

        let provider = EmbyProvider(connection: mutableConnection)
        let libraries = try await provider.fetchLibraries()

        return libraries.map { lib in
            LibraryMetadata(
                id: lib.id,
                name: lib.name,
                type: determineLibraryType(from: lib.type),
                itemCount: 0,
                audioBookCount: 0,
                collectionType: lib.type
            )
        }
    }
}

struct LibrarySelectionView: View {
    let backendName: String
    let libraries: [LibraryMetadata]
    let backendType: BackendConfig.BackendType
    @Binding var selectedLibraryIds: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(
        backendName: String,
        libraries: [LibraryMetadata],
        backendType: BackendConfig.BackendType,
        selectedLibraryIds: Binding<Set<String>>
    ) {
        self.backendName = backendName
        self.libraries = libraries
        self.backendType = backendType
        self._selectedLibraryIds = selectedLibraryIds
    }

    var body: some View {
        NavigationStack {
            List {
                if libraries.isEmpty {
                    Section {
                        Text("No libraries found on this server.")
                            .foregroundColor(Theme.secondaryText)
                    }
                } else {
                    Section {
                        ForEach(libraries) { library in
                            Button {
                                toggle(library.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: library.type.icon)
                                        .foregroundColor(Theme.primaryColor)
                                        .frame(width: 22)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(library.name)
                                            .foregroundColor(Theme.primaryText)
                                        Text(library.type.displayName)
                                            .font(.caption)
                                            .foregroundColor(Theme.secondaryText)
                                    }

                                    Spacer()

                                    if selectedLibraryIds.contains(library.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundColor(Theme.tertiaryText)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Choose which libraries to include")
                    } footer: {
                        Text("You can skip this and change it later.")
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                    }
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            #endif
            .background(Theme.backgroundColor)
            .navigationTitle("Libraries")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !libraries.isEmpty {
                    HStack {
                        Button("Select All") {
                            selectedLibraryIds = Set(libraries.map { $0.id })
                        }
                        Spacer()
                        Button("Clear") {
                            selectedLibraryIds.removeAll()
                        }
                    }
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Theme.cardBackground)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedLibraryIds.contains(id) {
            selectedLibraryIds.remove(id)
        } else {
            selectedLibraryIds.insert(id)
        }
    }
}
