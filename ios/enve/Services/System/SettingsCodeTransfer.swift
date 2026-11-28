#if os(iOS)
import CSettingsPairing
import CryptoKit
import Foundation
import Network
import Observation

@MainActor
@Observable
final class SettingsCodeTransferOffer {
    enum Status { case waiting, approval, sent, expired }

    let code = (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
    private(set) var status = Status.waiting
    private let listener: NWListener
    private let backup: (String) async throws -> Data
    private var readiness: CheckedContinuation<Void, any Error>?
    private var approval: CheckedContinuation<Bool, Never>?
    private var peer: NWConnection?
    private var expiry: Task<Void, Never>?
    private var attempts = 0

    private init(backup: @escaping (String) async throws -> Data) throws {
        guard let host = SettingsQRTransferOffer.wifiAddress() else { throw SettingsQRTransferError.noWiFi }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: "Enve " + UUID().uuidString, type: SettingsCodeTransfer.serviceType)
        self.backup = backup
    }

    static func start(backup: @escaping (String) async throws -> Data) async throws -> SettingsCodeTransferOffer {
        let offer = try SettingsCodeTransferOffer(backup: backup)
        try await withTaskCancellationHandler {
            try await offer.startListening()
        } onCancel: {
            Task { @MainActor in offer.close() }
        }
        try Task.checkCancellation()
        return offer
    }

    private func startListening() async throws {
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case .add = change {
                Task { @MainActor in
                    self?.readiness?.resume()
                    self?.readiness = nil
                }
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.close() } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        expiry = Task { [weak self] in
            if (try? await Task.sleep(for: .seconds(90))) != nil { self?.close() }
        }
        let registrationTimeout = Task { [weak self] in
            if (try? await Task.sleep(for: .seconds(8))) != nil { self?.close() }
        }
        defer { registrationTimeout.cancel() }
        try await withCheckedThrowingContinuation {
            readiness = $0
            listener.start(queue: .main)
        }
    }

    func approve() {
        approval?.resume(returning: true)
        approval = nil
    }

    func close() {
        expiry?.cancel()
        expiry = nil
        if status != .sent { status = .expired }
        listener.cancel()
        peer?.cancel()
        peer = nil
        readiness?.resume(throwing: SettingsQRTransferError.connection)
        readiness = nil
        approval?.resume(returning: false)
        approval = nil
    }

    private func accept(_ connection: NWConnection) {
        guard status == .waiting, peer == nil, attempts < 5 else { connection.cancel(); return }
        attempts += 1
        peer = connection
        connection.start(queue: .main)
        Task {
            let timeout = SettingsCodeTransfer.timeout(connection, after: .seconds(7))
            defer {
                timeout.cancel()
                connection.cancel()
                if peer === connection { peer = nil }
                if status == .approval || attempts >= 5 { close() }
            }
            do {
                let key = try await SettingsCodeTransfer.pair(code, sender: true, connection: connection)
                timeout.cancel()
                guard status == .waiting else { return }
                guard await withCheckedContinuation({ continuation in
                    approval = continuation
                    status = .approval
                }) else { return }
                let payload = try await backup(SettingsCodeTransfer.passphrase(key))
                guard status == .approval else { return }
                try await SettingsCodeTransfer.writeFrame(payload, on: connection)
                guard status == .approval else { return }
                status = .sent
                close()
            } catch {}
        }
    }
}

@MainActor
enum SettingsCodeTransfer {
    static let serviceType = "_enve-settings._tcp"

    static func receive(_ code: String) async throws -> (EncryptedSettingsBackup, String) {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw SettingsQRTransferError.invalidCode
        }
        let endpoints = await discover()
        for endpoint in endpoints.prefix(8) {
            try Task.checkCancellation()
            let parameters = NWParameters.tcp
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let connection = NWConnection(to: endpoint, using: parameters)
            let handshakeTimeout = timeout(connection, after: .seconds(7))
            defer {
                handshakeTimeout.cancel()
                connection.cancel()
            }
            let key: Data? = await withTaskCancellationHandler {
                connection.start(queue: .main)
                return try? await pair(code, sender: false, connection: connection)
            } onCancel: {
                connection.cancel()
            }
            guard let key else { continue }
            handshakeTimeout.cancel()
            let expiry = timeout(connection, after: .seconds(90))
            defer { expiry.cancel() }
            let data = try await withTaskCancellationHandler {
                try await readFrame(limit: SettingsQRTransfer.maxBytes, on: connection)
            } onCancel: {
                connection.cancel()
            }
            return (try JSONDecoder().decode(EncryptedSettingsBackup.self, from: data), passphrase(key))
        }
        try Task.checkCancellation()
        throw SettingsQRTransferError.connection
    }

    private static func discover() async -> [NWEndpoint] {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        let (updates, continuation) = AsyncStream.makeStream(of: Set<NWBrowser.Result>.self, bufferingPolicy: .bufferingNewest(1))
        browser.browseResultsChangedHandler = { results, _ in continuation.yield(results) }
        browser.stateUpdateHandler = { state in
            if case .failed = state { continuation.finish() }
        }
        let expiry = Task {
            if (try? await Task.sleep(for: .seconds(4))) != nil { continuation.finish() }
        }
        defer {
            expiry.cancel()
            browser.cancel()
            continuation.finish()
        }
        browser.start(queue: .main)
        var endpoints: [NWEndpoint] = []
        for await results in updates {
            endpoints = results.map(\.endpoint)
        }
        return endpoints
    }

    static func pair(_ code: String, sender: Bool, connection: NWConnection) async throws -> Data {
        let digits = Array(code.utf8)
        guard digits.count == 6, let exchange = digits.withUnsafeBufferPointer({ enve_pairing_create($0.baseAddress, sender) }) else {
            throw SettingsQRTransferError.invalidCode
        }
        defer { enve_pairing_free(exchange) }
        for round: Int32 in [1, 2] {
            var buffer = [UInt8](repeating: 0, count: 512)
            let length = buffer.withUnsafeMutableBufferPointer { enve_pairing_write(exchange, round, $0.baseAddress, $0.count) }
            guard length > 0 else { throw SettingsQRTransferError.connection }
            try await writeFrame(Data(buffer.prefix(length)), on: connection)
            let message = try await readFrame(limit: 512, on: connection)
            let accepted = message.withUnsafeBytes {
                enve_pairing_read(exchange, round, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
            guard accepted else { throw SettingsQRTransferError.connection }
        }
        var secret = [UInt8](repeating: 0, count: 32)
        defer { _ = secret.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard secret.withUnsafeMutableBufferPointer({ enve_pairing_derive(exchange, $0.baseAddress) }) else {
            throw SettingsQRTransferError.connection
        }
        let key = SymmetricKey(data: secret)
        let local = Data("enve.settings.code.v1.\(sender ? "sender" : "receiver")".utf8)
        let remote = Data("enve.settings.code.v1.\(sender ? "receiver" : "sender")".utf8)
        if !sender { try await SettingsQRTransfer.send(Data(HMAC<SHA256>.authenticationCode(for: local, using: key)), to: connection) }
        let proof = try await SettingsQRTransfer.read(32, from: connection)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: remote, using: key) else {
            throw SettingsQRTransferError.invalidCode
        }
        if sender { try await SettingsQRTransfer.send(Data(HMAC<SHA256>.authenticationCode(for: local, using: key)), to: connection) }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("enve.settings.code.v1.backup".utf8), using: key))
    }

    static func passphrase(_ key: Data) -> String {
        SettingsTransferCode.passphrase(for: key)
    }

    static func timeout(_ connection: NWConnection, after duration: Duration) -> Task<Void, Never> {
        Task {
            if (try? await Task.sleep(for: duration)) != nil { connection.cancel() }
        }
    }

    private static func readFrame(limit: Int, on connection: NWConnection) async throws -> Data {
        let header = try await SettingsQRTransfer.read(4, from: connection)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...limit).contains(size) else { throw SettingsQRTransferError.connection }
        return try await SettingsQRTransfer.read(size, from: connection)
    }

    static func writeFrame(_ data: Data, on connection: NWConnection) async throws {
        guard (1...SettingsQRTransfer.maxBytes).contains(data.count) else { throw SettingsQRTransferError.connection }
        var size = UInt32(data.count).bigEndian
        try await SettingsQRTransfer.send(withUnsafeBytes(of: &size) { Data($0) } + data, to: connection)
    }
}
#endif
