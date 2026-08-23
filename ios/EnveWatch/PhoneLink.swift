import Foundation
import Observation
import WatchConnectivity

enum PhoneLinkError: LocalizedError {
    case notReachable
    case badReply
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notReachable: return "iPhone is not reachable. Open Enve on your iPhone and try again."
        case .badReply: return "Received an invalid reply from the iPhone."
        case .remote(let message): return message
        }
    }
}

struct EmptyPayload: Codable, Sendable {}

@MainActor
@Observable
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    private(set) var isReachable = false
    private(set) var isActivated = false
    private(set) var nowPlaying = WatchNowPlayingPayload.empty

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    var nowPlayingIsLive: Bool {
        nowPlaying.isPlaying && Date().timeIntervalSince(nowPlaying.sentAt) < 60
    }

    var remotePosition: TimeInterval {
        guard nowPlaying.hasBook else { return 0 }
        guard nowPlayingIsLive else { return nowPlaying.position }
        let elapsed = Date().timeIntervalSince(nowPlaying.sentAt) * nowPlaying.speed
        return min(nowPlaying.position + elapsed, nowPlaying.duration)
    }

    func request<T: Decodable & Sendable>(_ kind: WatchWire.Kind, _ payload: some Encodable, as type: T.Type) async throws -> T {
        guard WCSession.default.activationState == .activated else { throw PhoneLinkError.notReachable }
        return try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(
                WatchWire.envelope(kind, payload),
                replyHandler: { @Sendable reply in
                    if let data = reply[WatchWire.dataKey] as? Data,
                        let value = try? JSONDecoder().decode(T.self, from: data)
                    {
                        continuation.resume(returning: value)
                    } else if let message = reply[WatchWire.errorKey] as? String {
                        continuation.resume(throwing: PhoneLinkError.remote(message))
                    } else if reply["ok"] != nil, let empty = EmptyPayload() as? T {
                        continuation.resume(returning: empty)
                    } else {
                        continuation.resume(throwing: PhoneLinkError.badReply)
                    }
                },
                errorHandler: { @Sendable error in
                    continuation.resume(throwing: error)
                }
            )
        }
    }

    func sendCommand(_ command: WatchCommandPayload) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.sendMessage(WatchWire.envelope(.command, command), replyHandler: nil, errorHandler: nil)
    }

    func reportProgress(_ report: WatchProgressReport) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(WatchWire.envelope(.reportProgress, report), replyHandler: nil) { @Sendable _ in

                WCSession.default.transferUserInfo(WatchWire.envelope(.reportProgress, report))
            }
        } else {
            session.transferUserInfo(WatchWire.envelope(.reportProgress, report))
        }
    }

    func requestFreshNowPlaying() {
        Task {
            if let payload = try? await request(.requestNowPlaying, EmptyPayload(), as: WatchNowPlayingPayload.self) {
                apply(payload)
            }
        }
    }

    private func apply(_ payload: WatchNowPlayingPayload) {
        guard payload.sentAt >= nowPlaying.sentAt else { return }
        let phoneJustStarted = payload.isPlaying && !nowPlaying.isPlaying
        nowPlaying = payload

        if phoneJustStarted, WatchPlayerModel.shared.isPlaying {
            WatchPlayerModel.shared.togglePlay()
        }
    }

    fileprivate func handleIncoming(_ message: [String: Any]) {
        guard let kind = WatchWire.kind(of: message) else { return }
        switch kind {
        case .nowPlaying:
            if let payload = WatchWire.payload(WatchNowPlayingPayload.self, from: message) {
                apply(payload)
            }
        default:
            break
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let cached = UncheckedSendableBox(session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            let link = PhoneLink.shared
            link.isActivated = activationState == .activated
            link.isReachable = reachable

            if activationState == .activated {
                WCSession.default.sendMessage([:], replyHandler: nil, errorHandler: nil)
            }
            link.handleIncoming(cached.value)
            if activationState == .activated {
                if reachable {
                    link.requestFreshNowPlaying()
                }

                Task { await WatchLibraryModel.shared.refreshIfStale() }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            PhoneLink.shared.isReachable = reachable
            if reachable {
                PhoneLink.shared.requestFreshNowPlaying()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let boxed = UncheckedSendableBox(applicationContext)
        Task { @MainActor in
            PhoneLink.shared.handleIncoming(boxed.value)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let boxed = UncheckedSendableBox(message)
        Task { @MainActor in
            PhoneLink.shared.handleIncoming(boxed.value)
        }
    }
}

nonisolated struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}
