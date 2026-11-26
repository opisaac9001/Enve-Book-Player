#if os(iOS)
import CryptoKit
import Darwin
import Foundation
import Network
import Observation

nonisolated struct SettingsTransferCode {
    let host: String
    let port: UInt16
    let key: Data

    var passphrase: String { Self.passphrase(for: key) }

    static func passphrase(for key: Data) -> String {
        key.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    var text: String { "enve-settings:1:\(host):\(port):\(passphrase)" }

    init?(host: String, port: UInt16, key: Data) {
        guard Self.isLocalAddress(host), port != 0, key.count == 32 else { return nil }
        self.host = host
        self.port = port
        self.key = key
    }

    init?(text: String) {
        guard text.utf8.count <= 128 else { return nil }
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "enve-settings", fields[1] == "1",
            let port = UInt16(fields[3]), fields[4].count == 43,
            let key = Data(base64Encoded: fields[4].replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "=")
        else { return nil }
        self.init(host: String(fields[2]), port: port, key: key)
    }

    static func isLocalAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> UInt8? in
            guard let byte = UInt8(part), String(byte) == part else { return nil }
            return byte
        }
        guard parts.count == 4, octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
    }
}

nonisolated enum SettingsQRTransferError: LocalizedError {
    case noWiFi, invalidCode, connection
    var errorDescription: String? {
        switch self {
        case .noWiFi: "Connect both devices to the same Wi-Fi network and try again."
        case .invalidCode: "Scan a fresh Enve settings transfer code."
        case .connection: "Couldn't complete the transfer. Check Wi-Fi or try importing a backup file."
        }
    }
}

@MainActor
@Observable
final class SettingsQRTransferOffer {
    enum Status { case waiting, sent, expired }

    private let listener: NWListener
    private let host: String
    private let key: Data
    private let payload: Data
    private var peer: NWConnection?
    private var timer: Task<Void, Never>?
    private var readiness: CheckedContinuation<Void, any Error>?
    private(set) var status = Status.waiting

    var code: SettingsTransferCode? {
        guard status == .waiting, let port = listener.port?.rawValue else { return nil }
        return SettingsTransferCode(host: host, port: port, key: key)
    }

    private init(host: String, key: Data, payload: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        self.host = host
        self.key = key
        self.payload = payload
    }

    static func start(key: Data, payload: Data) async throws -> SettingsQRTransferOffer {
        guard payload.count <= SettingsQRTransfer.maxBytes, let host = wifiAddress() else {
            throw SettingsQRTransferError.noWiFi
        }
        let offer = try SettingsQRTransferOffer(host: host, key: key, payload: payload)
        try await withTaskCancellationHandler {
            try await offer.startListening()
        } onCancel: {
            Task { @MainActor in offer.close() }
        }
        try Task.checkCancellation()
        return offer
    }

    private func startListening() async throws {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.readiness?.resume()
                    self.readiness = nil
                case .failed, .cancelled:
                    if self.status == .waiting { self.close() }
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(90))
                self?.close()
            } catch {}
        }
        try await withCheckedThrowingContinuation { continuation in
            readiness = continuation
            listener.start(queue: .main)
        }
    }

    func close() {
        timer?.cancel()
        timer = nil
        if status == .waiting { status = .expired }
        listener.cancel()
        peer?.cancel()
        peer = nil
        readiness?.resume(throwing: SettingsQRTransferError.connection)
        readiness = nil
    }

    private func accept(_ connection: NWConnection) {
        guard peer == nil, status == .waiting else { connection.cancel(); return }
        peer = connection
        connection.start(queue: .main)
        Task { [weak self] in
            guard let self else { connection.cancel(); return }
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(4))
                    connection.cancel()
                } catch {}
            }
            defer {
                timeout.cancel()
                connection.cancel()
                if self.peer === connection { self.peer = nil }
            }
            do {
                let challenge = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
                try await SettingsQRTransfer.send(challenge, to: connection)
                let proof = try await SettingsQRTransfer.read(32, from: connection)
                guard SettingsQRTransfer.verify(proof, key: self.key, challenge: challenge),
                    self.status == .waiting
                else { return }
                timeout.cancel()
                var length = UInt32(self.payload.count).bigEndian
                let header = withUnsafeBytes(of: &length) { Data($0) }
                try await SettingsQRTransfer.send(header + self.payload, to: connection)
                if self.status == .waiting { self.status = .sent }
                self.close()
            } catch {}
        }
    }

    private static func wifiAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }
        var item: UnsafeMutablePointer<ifaddrs>? = first
        var fallback: String?
        while let current = item {
            let entry = current.pointee
            item = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                let name = entry.ifa_name, entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
            else { continue }
            let interface = String(cString: name)
            guard interface.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if SettingsTransferCode.isLocalAddress(value) {
                    if interface == "en0" { return value }
                    fallback = fallback ?? value
                }
            }
        }
        return fallback
    }
}

nonisolated enum SettingsQRTransfer {
    static let maxBytes = 16 * 1024 * 1024

    static func receive(_ code: SettingsTransferCode) async throws -> EncryptedSettingsBackup {
        guard let port = NWEndpoint.Port(rawValue: code.port) else { throw SettingsQRTransferError.invalidCode }
        let connection = NWConnection(host: NWEndpoint.Host(code.host), port: port, using: .tcp)
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(12))
                connection.cancel()
            } catch {}
        }
        defer {
            timeout.cancel()
            connection.cancel()
        }
        return try await withTaskCancellationHandler {
            connection.start(queue: .global())
            let challenge = try await read(16, from: connection)
            let mac = HMAC<SHA256>.authenticationCode(for: request(challenge), using: SymmetricKey(data: code.key))
            try await send(Data(mac), to: connection)
            let header = try await read(4, from: connection)
            let size = header.reduce(0) { ($0 << 8) | Int($1) }
            guard (1...maxBytes).contains(size) else { throw SettingsQRTransferError.connection }
            let data = try await read(size, from: connection)
            return try JSONDecoder().decode(EncryptedSettingsBackup.self, from: data)
        } onCancel: {
            connection.cancel()
        }
    }

    static func verify(_ mac: Data, key: Data, challenge: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: request(challenge), using: SymmetricKey(data: key))
    }

    private static func request(_ challenge: Data) -> Data {
        Data("enve.settings.transfer.request.v1".utf8) + challenge
    }

    static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    static func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let next = min(count - result.count, 64 * 1024)
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(minimumIncompleteLength: next, maximumLength: next) { bytes, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: SettingsQRTransferError.connection) }
                }
            }
            result.append(data)
        }
        return result
    }
}
#endif
