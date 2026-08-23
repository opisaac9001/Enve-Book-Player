import Foundation
import Logging
import Network
import Observation
import UIKit

@MainActor
@Observable
final class CompanionReceiverService_tvOS {
    static let shared = CompanionReceiverService_tvOS()

    enum ReceiverState: Equatable {
        case idle
        case discovering
        case connected(CompanionSession)
        case error(NSError)

        static func == (lhs: ReceiverState, rhs: ReceiverState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.discovering, .discovering): return true
            case (.connected(let a), .connected(let b)): return a.id == b.id
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: ReceiverState = .idle

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var session: CompanionSession?

    private var pendingLengthBuffer: Data = Data()
    private var pendingMessageBuffer: Data = Data()
    private var expectedMessageLength: UInt32?

    private enum PendingBinary {
        case png
        case videoFrame(VideoFramePayload)
    }
    private var pendingBinaryKind: PendingBinary?
    private var pendingBinaryLength: UInt32?
    private var pendingBinaryBuffer: Data = Data()

    private var keepaliveTask: Task<Void, Never>?
    private var lastInboundAt: Date = .distantPast
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var recentlyFailedEndpoints: [String: Date] = [:]

    let videoDecoder = CompanionVideoDecoder_tvOS()

    private init() {}

    func startDiscovering() async {
        guard browser == nil else { return }
        state = .discovering

        let parameters = NWParameters.tcp
        let browser = NWBrowser(
            for: .bonjour(type: CompanionService.bonjourType, domain: CompanionService.bonjourDomain),
            using: parameters
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results)
            }
        }
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor [weak self] in
                switch browserState {
                case .ready:
                    AppLogger.network.info("[Companion] Browser ready")
                case .failed(let error):
                    AppLogger.network.warning("[Companion] Browser failed: \(error.localizedDescription)")
                    self?.state = .error(error as NSError)
                default:
                    break
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopDiscovering() {
        browser?.cancel()
        browser = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        connection?.cancel()
        connection = nil
        session = nil
        resetParserBuffers()
        state = .idle
    }

    func sendPageCommand(_ direction: PageCommandPayload.Direction) {
        sendControlMessage(type: .pageCommand, payload: PageCommandPayload(direction: direction))
    }

    func sendReadAloudCommand(_ action: ReadAloudCommandPayload.Action) {
        sendControlMessage(type: .readAloudCommand, payload: ReadAloudCommandPayload(action: action))
    }

    private func sendControlMessage<T: Encodable>(type: CompanionMessageType, payload: T) {
        guard let connection else { return }
        do {
            let payloadJSON = try JSONEncoder().encode(payload)
            let envelope = CompanionMessageEnvelope(type: type, payloadJSON: payloadJSON)
            let envelopeData = try JSONEncoder().encode(envelope)
            var lengthBE = UInt32(envelopeData.count).bigEndian
            let lengthData = Data(bytes: &lengthBE, count: 4)
            connection.send(
                content: lengthData + envelopeData,
                completion: .contentProcessed { error in
                    if let error {
                        AppLogger.network.warning("[Companion] send \(type.rawValue) failed: \(error.localizedDescription)")
                    }
                }
            )
        } catch {
            AppLogger.network.warning("[Companion] encode \(type.rawValue) failed: \(error.localizedDescription)")
        }
    }

    private func sendViewportInfo() {
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let payload = ViewportInfoPayload(
            width: Double(screen.width * scale),
            height: Double(screen.height * scale)
        )
        sendControlMessage(type: .viewportInfo, payload: payload)
        AppLogger.network.info("[Companion] Sent viewport \(Int(payload.width))×\(Int(payload.height))")
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        guard connection == nil, !results.isEmpty else { return }

        let now = Date()
        recentlyFailedEndpoints = recentlyFailedEndpoints.filter { now.timeIntervalSince($0.value) < 30 }
        guard let result = results.first(where: { recentlyFailedEndpoints["\($0.endpoint)"] == nil }) else {
            scheduleReconnectFromCachedResults()
            return
        }

        AppLogger.network.info("[Companion] Found broadcaster, connecting…")
        let endpoint = result.endpoint
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: .main)
        self.connection = connection

        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.session == nil, self.connection != nil else { return }
            AppLogger.network.warning("[Companion] Connect attempt timed out; will try other broadcasters")
            self.recentlyFailedEndpoints["\(endpoint)"] = Date()
            self.cleanupConnection()
        }
    }

    private func handleConnectionState(_ connState: NWConnection.State) {
        switch connState {
        case .ready:
            AppLogger.network.info("[Companion] Connection ready, waiting for sessionStart…")
            scheduleReceive()

            sendViewportInfo()
            startKeepalive()
        case .failed(let error):
            AppLogger.network.warning("[Companion] Connection failed: \(error.localizedDescription)")
            if session == nil {
                if let endpoint = connection?.endpoint {
                    recentlyFailedEndpoints["\(endpoint)"] = Date()
                }
            } else {
                state = .error(error as NSError)
            }
            cleanupConnection()
        case .cancelled:
            cleanupConnection()
        default:
            break
        }
    }

    private func cleanupConnection() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        connection?.cancel()
        connection = nil
        session = nil
        resetParserBuffers()
        if case .connected = state {
            state = .discovering
        }
        scheduleReconnectFromCachedResults()
    }

    private func startKeepalive() {
        lastInboundAt = Date()
        keepaliveTask?.cancel()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, self.connection != nil else { return }
                if Date().timeIntervalSince(self.lastInboundAt) > 15 {
                    AppLogger.network.warning("[Companion] No data from iPhone for 15s; dropping connection")
                    self.cleanupConnection()
                    return
                }
                self.sendControlMessage(type: .ping, payload: EmptyPayload())
            }
        }
    }

    private func scheduleReconnectFromCachedResults() {
        guard browser != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.connection == nil, let browser = self.browser else { return }
            self.handleBrowseResults(browser.browseResults)
        }
    }

    private func scheduleReceive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.feedParser(data)
                }
                if let error {
                    AppLogger.network.warning("[Companion] Receive error: \(error.localizedDescription)")
                    self.state = .error(error as NSError)
                    self.cleanupConnection()
                    return
                }
                if isComplete {
                    AppLogger.network.info("[Companion] Connection closed by peer")
                    self.cleanupConnection()
                    return
                }
                self.scheduleReceive()
            }
        }
    }

    private func feedParser(_ data: Data) {
        lastInboundAt = Date()
        var remaining = data
        while !remaining.isEmpty {
            if let binaryLength = pendingBinaryLength {

                let need = Int(binaryLength) - pendingBinaryBuffer.count
                let take = min(need, remaining.count)
                pendingBinaryBuffer.append(remaining.prefix(take))
                remaining = remaining.dropFirst(take)
                if pendingBinaryBuffer.count == Int(binaryLength) {
                    let payload = pendingBinaryBuffer
                    let kind = pendingBinaryKind
                    pendingBinaryBuffer = Data()
                    pendingBinaryLength = nil
                    pendingBinaryKind = nil
                    switch kind {
                    case .png:
                        handlePNGPayload(payload)
                    case .videoFrame(let meta):
                        handleVideoPayload(payload, meta: meta)
                    case .none:
                        break
                    }
                }
                continue
            }

            if expectedMessageLength == nil {

                let need = 4 - pendingLengthBuffer.count
                let take = min(need, remaining.count)
                pendingLengthBuffer.append(remaining.prefix(take))
                remaining = remaining.dropFirst(take)
                if pendingLengthBuffer.count == 4 {
                    let length = pendingLengthBuffer.withUnsafeBytes { ptr -> UInt32 in
                        ptr.load(as: UInt32.self).bigEndian
                    }
                    pendingLengthBuffer = Data()
                    if length == 0 || length > 100_000_000 {
                        AppLogger.network.warning("[Companion] Invalid message length \(length); dropping connection")
                        cleanupConnection()
                        return
                    }
                    expectedMessageLength = length
                }
                continue
            }

            let need = Int(expectedMessageLength!) - pendingMessageBuffer.count
            let take = min(need, remaining.count)
            pendingMessageBuffer.append(remaining.prefix(take))
            remaining = remaining.dropFirst(take)
            if pendingMessageBuffer.count == Int(expectedMessageLength!) {
                handleEnvelope(pendingMessageBuffer)
                pendingMessageBuffer = Data()
                expectedMessageLength = nil
            }
        }
    }

    private func handleEnvelope(_ data: Data) {
        do {
            let envelope = try JSONDecoder().decode(CompanionMessageEnvelope.self, from: data)
            switch envelope.type {
            case .sessionStart:
                let payload = try JSONDecoder().decode(SessionStartPayload.self, from: envelope.payloadJSON)
                handleSessionStart(payload)
            case .pageFrame:
                let payload = try JSONDecoder().decode(PageFramePayload.self, from: envelope.payloadJSON)

                pendingBinaryKind = .png
                pendingBinaryLength = UInt32(payload.imageByteCount) + 4
                pendingBinaryBuffer = Data()
                session?.pendingPageMetadata = payload
            case .videoStreamStart:
                let payload = try JSONDecoder().decode(VideoStreamStartPayload.self, from: envelope.payloadJSON)
                videoDecoder.reset()
                session?.isVideoStreaming = true
                AppLogger.network.info("[Companion] Video stream start \(payload.width)×\(payload.height)")
            case .videoFrame:
                let payload = try JSONDecoder().decode(VideoFramePayload.self, from: envelope.payloadJSON)

                pendingBinaryKind = .videoFrame(payload)
                pendingBinaryLength = UInt32(payload.byteCount) + 4
                pendingBinaryBuffer = Data()
            case .videoStreamStop:
                session?.isVideoStreaming = false
                videoDecoder.reset()
                AppLogger.network.info("[Companion] Video stream stopped")
            case .highlightUpdate:
                let payload = try JSONDecoder().decode(HighlightPayload.self, from: envelope.payloadJSON)
                session?.activeHighlight = payload.normalizedRect
            case .mediaOverlayState:
                let payload = try JSONDecoder().decode(MediaOverlayStatePayload.self, from: envelope.payloadJSON)
                session?.isMediaOverlayPlaying = payload.isPlaying
                if let speed = payload.speed {
                    session?.mediaOverlaySpeed = speed
                }
            case .sessionEnd:
                AppLogger.network.info("[Companion] Session ended by broadcaster")
                cleanupConnection()
            case .pageCommand, .viewportInfo, .readAloudCommand, .ping, .pong:

                break
            }
            updatePublishedState()
        } catch {
            AppLogger.network.warning("[Companion] Decode failed: \(error.localizedDescription)")
        }
    }

    private func handlePNGPayload(_ data: Data) {
        guard let session, let pendingMeta = session.pendingPageMetadata else { return }

        let pngBytes = data.count >= 4 ? data.dropFirst(4) : data
        guard let image = UIImage(data: pngBytes) else {
            AppLogger.network.warning("[Companion] Failed to decode PNG (\(pngBytes.count) bytes)")
            return
        }
        session.currentPageImage = image
        session.pageIndex = pendingMeta.pageIndex
        session.totalPages = pendingMeta.totalPages
        session.chapterTitle = pendingMeta.chapterTitle
        session.pendingPageMetadata = nil

        session.activeHighlight = nil
        updatePublishedState()
    }

    private func handleVideoPayload(_ data: Data, meta: VideoFramePayload) {
        let accessUnit = data.count >= 4 ? Data(data.dropFirst(4)) : data
        videoDecoder.decode(
            accessUnit: accessUnit,
            isKeyframe: meta.isKeyframe,
            ptsMillis: meta.ptsMillis
        )
    }

    private func handleSessionStart(_ payload: SessionStartPayload) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        let session = CompanionSession(
            id: UUID(),
            bookTitle: payload.bookTitle,
            bookStableId: payload.bookStableId,
            deviceName: payload.deviceName,
            hasMediaOverlay: payload.hasMediaOverlay
        )
        self.session = session
        state = .connected(session)
        AppLogger.network.info("[Companion] Session started: \(payload.bookTitle) on \(payload.deviceName)")
    }

    private func updatePublishedState() {

        if let session, case .connected = state {
            state = .connected(session)
        }
    }

    private func resetParserBuffers() {
        pendingLengthBuffer = Data()
        pendingMessageBuffer = Data()
        expectedMessageLength = nil
        pendingBinaryKind = nil
        pendingBinaryLength = nil
        pendingBinaryBuffer = Data()
    }
}

@MainActor
@Observable
final class CompanionSession: Identifiable {
    let id: UUID
    let bookTitle: String
    let bookStableId: String
    let deviceName: String
    let hasMediaOverlay: Bool

    var currentPageImage: UIImage?
    var pageIndex: Int = 0
    var totalPages: Int = 0
    var chapterTitle: String?
    var activeHighlight: NormalizedRect?
    var isMediaOverlayPlaying: Bool = false
    var mediaOverlaySpeed: Double = 1.0

    var isVideoStreaming: Bool = false

    var pendingPageMetadata: PageFramePayload?

    init(id: UUID, bookTitle: String, bookStableId: String, deviceName: String, hasMediaOverlay: Bool) {
        self.id = id
        self.bookTitle = bookTitle
        self.bookStableId = bookStableId
        self.deviceName = deviceName
        self.hasMediaOverlay = hasMediaOverlay
    }
}
