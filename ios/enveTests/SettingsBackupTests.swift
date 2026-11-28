import Foundation
import Testing

@testable import enve

@MainActor
struct SettingsBackupTests {
    private let passphrase = "test-only portable settings passphrase"

    @Test func encryptedEnvelopeUsesFreshSaltAndRejectsWrongPassphraseOrTampering() throws {
        let payload = Data("portable backup fixture".utf8)
        let first = try EncryptedSettingsBackup.seal(payload, passphrase: passphrase)
        let second = try EncryptedSettingsBackup.seal(payload, passphrase: passphrase)

        #expect(first.salt != second.salt)
        #expect(first.payload != second.payload)
        #expect(try first.open(passphrase: passphrase) == payload)
        #expect(throws: SettingsBackupError.self) { try first.open(passphrase: "incorrect test passphrase") }

        var damaged = first.payload
        damaged[damaged.index(before: damaged.endIndex)] ^= 1
        let tampered = EncryptedSettingsBackup(format: first.format, version: first.version, salt: first.salt, payload: damaged)
        #expect(throws: SettingsBackupError.self) { try tampered.open(passphrase: passphrase) }
    }

    @Test func sourceExportRespectsSignInSelectionAndKeepsPublicConfiguration() throws {
        var connection = ServerConnection(
            name: "Shelf", url: "https://reader:fixture@books.invalid/feed?key=fixture#section",
            type: .opds, username: "reader", password: "fixture-password", token: "fixture-api-key",
            selectedLibraryIds: ["library"], customHeaders: [
                "Accept-Language": "en", "Authorization": "Bearer fixture", "Cookie": "session=fixture",
            ], authMode: .token
        )
        connection.knownLibraryIds = ["library", "other"]

        let configuration = try #require(PortableSettingsBackup.Source(connection, includeSignIns: false))
        #expect(configuration.url == "https://books.invalid/feed")
        #expect(configuration.headers == ["Accept-Language": "en"])
        #expect(configuration.password == nil)
        #expect(configuration.apiKey == nil)
        #expect(configuration.needsSignIn)
        #expect(configuration.selectedLibraryIds == ["library"])
        #expect(configuration.knownLibraryIds == ["library", "other"])

        let signedIn = try #require(PortableSettingsBackup.Source(connection, includeSignIns: true))
        #expect(signedIn.password == "fixture-password")
        #expect(signedIn.apiKey == "fixture-api-key")
        #expect(signedIn.headers?["Cookie"] == nil)
        #expect(signedIn.needsSignIn)

        connection.authMode = .sso
        let browser = try #require(PortableSettingsBackup.Source(connection, includeSignIns: true))
        #expect(browser.password == nil)
        #expect(browser.apiKey == nil)
        #expect(browser.needsSignIn)
    }

    @Test func restoreKeepsExistingSourceAndMakesAnImportedSourceIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "SettingsBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let storage = ProfileStorageLocations(
            profileID: FamilyProfile.ownerID, documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"), cachesDirectory: root.appendingPathComponent("Caches")
        )
        let session = try ProfileSession(
            profile: FamilyProfile(id: FamilyProfile.ownerID, name: "Test Owner", role: .adult),
            storage: storage, defaults: defaults
        )
        defer {
            for connection in session.providerConnections.connections {
                session.keychain.deleteAll(forConnectionId: connection.id.uuidString)
            }
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let original = ServerConnection(name: "Keep this one", url: "https://books.invalid/feed", type: .opds, username: "reader")
        session.providerConnections.connections = [original]
        let duplicate = ServerConnection(name: "Duplicate", url: "HTTPS://BOOKS.INVALID:443/feed/", type: .opds, username: "reader")
        let fresh = ServerConnection(name: "New Library", url: "https://silo.invalid", type: .silo, username: "reader", authMode: .usernamePassword)
        let signedIn = ServerConnection(
            name: "Saved Sign-in", url: "https://saved.invalid", type: .silo,
            username: "reader", password: "fixture-password", authMode: .usernamePassword
        )
        let sources = try [duplicate, fresh, signedIn].map { try #require(PortableSettingsBackup.Source($0, includeSignIns: true)) }
        let backup = PortableSettingsBackup(settings: nil, sources: sources)
        let ids = Set(sources.map(\.id))

        let first = try SettingsBackupService.shared.restore(backup, includeSettings: false, sourceIDs: ids, integrations: [], session: session)
        #expect(first.restoredSources == 2)
        #expect(first.skippedSources == 1)
        #expect(first.signInsNeeded == 1)
        let imported = try #require(session.providerConnections.connections.first { $0.name == "New Library" })
        #expect(imported.id != fresh.id)
        #expect(imported.name == "New Library")
        #expect(session.authenticationFailures.isBlocked(connectionId: imported.id))
        #expect(session.providerConnections.connections.first == original)
        let restoredSignIn = try #require(session.providerConnections.connections.last)
        #expect(restoredSignIn.name == "Saved Sign-in")
        #expect(session.keychain.password(forConnectionId: restoredSignIn.id.uuidString) == "fixture-password")
        #expect(!session.authenticationFailures.isBlocked(connectionId: restoredSignIn.id))

        let repeated = try SettingsBackupService.shared.restore(backup, includeSettings: false, sourceIDs: ids, integrations: [], session: session)
        #expect(repeated.restoredSources == 0)
        #expect(repeated.skippedSources == 3)
        #expect(session.providerConnections.connections.count == 3)
        await session.retire()
    }

    @Test func versionOneSettingsFileStillOpens() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = SettingsBackupDocument(
            version: 1, exportedAt: Date(timeIntervalSince1970: 1_000), preferences: UserPreferences(),
            perBookSpeeds: ["book.fixture": 1.5]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url)
        guard case .settings(let imported) = try SettingsBackupService.shared.readBackup(from: url) else {
            Issue.record("Expected the original JSON backup format")
            return
        }
        #expect(imported.perBookSpeeds == document.perBookSpeeds)
    }

    @Test func transferCodeOnlyAcceptsPrivateNumericAddresses() throws {
        let key = Data(0..<32)
        let code = try #require(SettingsTransferCode(host: "192.168.2.4", port: 49152, key: key))
        let decoded = try #require(SettingsTransferCode(text: code.text))
        #expect(decoded.host == code.host)
        #expect(decoded.port == code.port)
        #expect(decoded.key == key)
        for host in ["localhost", "127.0.0.1", "8.8.8.8", "192.168.000.4"] {
            #expect(SettingsTransferCode(host: host, port: 49152, key: key) == nil)
        }
        #expect(SettingsTransferCode(host: "192.168.2.4", port: 0, key: key) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_TEST_TYPED_PEER_CODE"] != nil))
    func receivesSettingsFromAnAndroidTypedCodeOffer() async throws {
        let code = try #require(ProcessInfo.processInfo.environment["ENVE_TEST_TYPED_PEER_CODE"])
        let (encrypted, passphrase) = try await SettingsCodeTransfer.receive(code)
        let payload = try encrypted.open(passphrase: passphrase)
        let portable = try JSONDecoder().decode(PortableSettingsBackup.self, from: payload)
        let shared = try #require(portable.sharedSettings)
        var preferences = UserPreferences()
        shared.apply(to: &preferences)
        #expect(preferences.skipForwardAmount == 45)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_TEST_TYPED_SENDER"] == "1"))
    func sendsFixtureAfterTypedCodeApproval() async throws {
        let payload = Data(#"{"sources":[],"sharedSettings":{"skipForwardSeconds":45}}"#.utf8)
        var sealed = false
        let offer = try await SettingsCodeTransferOffer.start { passphrase in
            sealed = true
            return try JSONEncoder().encode(EncryptedSettingsBackup.seal(payload, passphrase: passphrase))
        }
        let codeFile = FileManager.default.temporaryDirectory.appendingPathComponent("enve-test-typed-code")
        defer {
            offer.close()
            try? FileManager.default.removeItem(at: codeFile)
        }
        try Data(offer.code.utf8).write(to: codeFile)
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            switch offer.status {
            case .waiting:
                try await Task.sleep(for: .milliseconds(100))
            case .approval:
                #expect(!sealed)
                offer.approve()
                while offer.status == .approval {
                    try await Task.sleep(for: .milliseconds(100))
                }
            case .sent:
                #expect(sealed)
                return
            case .expired:
                throw SettingsQRTransferError.connection
            }
        }
        throw SettingsQRTransferError.connection
    }

    @Test func sharedSettingsOnlyChangeSupportedPreferences() throws {
        let payload = Data("""
            {"sources":[],"sharedSettings":{"themeMode":"DARK","defaultSpeed":1.4,"skipForwardSeconds":30}}
            """.utf8)
        let portable = try JSONDecoder().decode(PortableSettingsBackup.self, from: payload)
        let shared = try #require(portable.sharedSettings)
        var local = UserPreferences()
        local.skipBackwardAmount = 45
        shared.apply(to: &local)
        #expect(local.theme == .dark)
        #expect(local.playbackSpeed == 1.4)
        #expect(local.skipForwardAmount == 30)
        #expect(local.skipBackwardAmount == 45)
    }
}
