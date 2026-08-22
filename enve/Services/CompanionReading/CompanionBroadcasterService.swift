import CoreMedia
import CoreVideo
import Foundation
import Logging
import Network
import Observation

#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class CompanionBroadcasterService {
    public static let shared = CompanionBroadcasterService()

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var currentSession: SessionContext?

    private struct SessionContext {
        let bookTitle: String
        let bookStableId: String
        let hasMediaOverlay: Bool
        var pageSize: CGSize?
    }

    public private(set) var isBroadcasting: Bool = false
    public private(set) var isReceiverConnected: Bool = false
    public private(set) var isAdvertised: Bool = false

    @ObservationIgnored private var advertiseWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var advertiseRetryCount = 0

    public private(set) var receiverViewport: ViewportInfoPayload?

    @ObservationIgnored public var pageCommandHandler: ((PageCommandPayload.Direction) -> Void)?

    @ObservationIgnored public var viewportInfoHandler: ((ViewportInfoPayload) -> Void)?

    @ObservationIgnored public var readAloudCommandHandler: ((ReadAloudCommandPayload.Action) -> Void)?

    @ObservationIgnored public var receiverConnectedHandler: (() -> Void)?

    @ObservationIgnored private var inboundLengthBuffer = Data()
    @ObservationIgnored private var inboundMessageBuffer = Data()
    @ObservationIgnored private var inboundExpectedLength: UInt32?

    @ObservationIgnored private var videoEncoder: CompanionVideoEncoder?

    public private(set) var isVideoStreaming: Bool = false

    private init() {}

    public func start(bookTitle: String, bookStableId: String, hasMediaOverlay: Bool) async throws {
        await stop(reason: .userClosedReader)

        let context = SessionContext(
            bookTitle: bookTitle,
            bookStableId: bookStableId,
            hasMediaOverlay: hasMediaOverlay,
            pageSize: nil
        )
        currentSession = context

        advertiseRetryCount = 0
        try startListener(serviceName: deviceDisplayName(), context: context)
        self.isBroadcasting = true
        AppLogger.network.info("[Companion] Broadcasting started for '\(bookTitle)'")
        debugTrace("broadcasting started for '\(bookTitle)'")
    }

    private func startListener(serviceName: String, context: SessionContext) throws {
        let parameters = NWParameters.tcp

        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener = try NWListener(using: parameters)
        let txtRecord = makeTxtRecord(for: context)
        listener.service = NWListener.Service(
            name: serviceName,
            type: CompanionService.bonjourType,
            domain: nil,
            txtRecord: txtRecord
        )

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handleNewConnection(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleListenerStateChange(state)
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            Task { @MainActor [weak self] in
                self?.handleServiceRegistrationChange(change)
            }
        }

        listener.start(queue: .main)
        self.listener = listener
        armAdvertiseWatchdog()
    }

    private func handleServiceRegistrationChange(_ change: NWListener.ServiceRegistrationChange) {
        switch change {
        case .add(let endpoint):
            isAdvertised = true
            advertiseWatchdogTask?.cancel()
            advertiseWatchdogTask = nil
            AppLogger.network.info("[Companion] Advertised as \(endpoint.debugDescription)")
            debugTrace("advertised \(endpoint.debugDescription)")
        case .remove:
            isAdvertised = false
            AppLogger.network.warning("[Companion] Advertisement removed")
            debugTrace("advertisement removed")
            if connection == nil, listener != nil {
                armAdvertiseWatchdog()
            }
        @unknown default:
            break
        }
    }

    private func debugTrace(_ line: String) {
        #if DEBUG
        let url = URL.documentsDirectory.appendingPathComponent("enve_companion.txt")
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private func armAdvertiseWatchdog() {
        advertiseWatchdogTask?.cancel()
        advertiseWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.isAdvertised, self.listener != nil, self.connection == nil else { return }
            guard self.advertiseRetryCount < 4, let context = self.currentSession else {
                AppLogger.network.warning("[Companion] Advertisement never registered; giving up retries")
                return
            }
            self.advertiseRetryCount += 1
            AppLogger.network.warning("[Companion] Advertisement not registered; retrying (attempt \(self.advertiseRetryCount))")
            self.debugTrace("advertise retry \(self.advertiseRetryCount)")
            self.listener?.cancel()
            self.listener = nil
            let name = "\(self.deviceDisplayName()) (\(self.advertiseRetryCount + 1))"
            try? self.startListener(serviceName: name, context: context)
        }
    }

    public func stop(reason: SessionEndPayload.Reason = .userClosedReader) async {
        if isVideoStreaming {
            videoEncoder?.stop()
            videoEncoder = nil
            isVideoStreaming = false
        }
        if let connection {
            await sendEnvelope(
                type: .sessionEnd,
                payload: SessionEndPayload(reason: reason),
                on: connection
            )
            connection.cancel()
        }
        connection = nil
        listener?.cancel()
        listener = nil
        advertiseWatchdogTask?.cancel()
        advertiseWatchdogTask = nil
        isAdvertised = false
        currentSession = nil
        isBroadcasting = false
        isReceiverConnected = false
        receiverViewport = nil
        AppLogger.network.info("[Companion] Broadcasting stopped (reason: \(reason.rawValue))")
    }

    public func sendPage(image: UIImage, pageIndex: Int, totalPages: Int, chapterTitle: String? = nil) async {
        guard let connection else {
            AppLogger.network.warning("[Companion] sendPage skipped - no connection")
            return
        }
        guard let context = currentSession else {
            AppLogger.network.warning("[Companion] sendPage skipped - no session")
            return
        }
        guard let imageData = image.jpegData(compressionQuality: 0.85) ?? image.pngData() else {
            AppLogger.network.warning("[Companion] sendPage skipped - image encode failed")
            return
        }
        AppLogger.network.info("[Companion] sendPage: \(imageData.count) bytes")

        currentSession?.pageSize = image.size

        let payload = PageFramePayload(
            pageIndex: pageIndex,
            totalPages: totalPages,
            imageByteCount: imageData.count,
            chapterTitle: chapterTitle
        )
        guard let envelopeFrame = makeEnvelopeFrame(type: .pageFrame, payload: payload) else { return }
        var lengthBE = UInt32(imageData.count).bigEndian
        let lengthData = Data(bytes: &lengthBE, count: 4)
        await sendData(envelopeFrame + lengthData + imageData, on: connection)

        _ = context
    }

    public func sendHighlight(rect: CGRect, pageSize: CGSize, pageIndex: Int) async {
        guard let connection else { return }
        let normalized = NormalizedRect(rect: rect, in: pageSize)
        let payload = HighlightPayload(pageIndex: pageIndex, normalizedRect: normalized)
        await sendEnvelope(type: .highlightUpdate, payload: payload, on: connection)
    }

    public func sendMediaOverlayState(isPlaying: Bool, speed: Double? = nil) async {
        guard let connection else { return }
        let payload = MediaOverlayStatePayload(isPlaying: isPlaying, speed: speed)
        await sendEnvelope(type: .mediaOverlayState, payload: payload, on: connection)
    }

    public func startVideoStream(width: Int, height: Int) async {
        guard let connection, !isVideoStreaming else { return }

        let encoder = CompanionVideoEncoder(width: width, height: height)
        guard encoder.start() else {
            AppLogger.network.error("[Companion] video encoder failed to start")
            return
        }
        encoder.onAccessUnit = { [weak self] unit in
            Task { @MainActor [weak self] in
                await self?.sendVideoAccessUnit(unit)
            }
        }
        videoEncoder = encoder
        isVideoStreaming = true

        await sendEnvelope(
            type: .videoStreamStart,
            payload: VideoStreamStartPayload(width: width, height: height),
            on: connection
        )
        AppLogger.network.info("[Companion] Video stream started \(width)×\(height)")
    }

    public func encodeVideoFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        videoEncoder?.encode(pixelBuffer, presentationTime: presentationTime)
    }

    public func stopVideoStream() async {
        guard isVideoStreaming else { return }
        videoEncoder?.stop()
        videoEncoder = nil
        isVideoStreaming = false
        if let connection {
            await sendEnvelope(type: .videoStreamStop, payload: EmptyPayload(), on: connection)
        }
        AppLogger.network.info("[Companion] Video stream stopped")
    }

    private func sendVideoAccessUnit(_ unit: CompanionVideoEncoder.AccessUnit) async {
        guard let connection else { return }
        let payload = VideoFramePayload(
            byteCount: unit.data.count,
            isKeyframe: unit.isKeyframe,
            ptsMillis: unit.ptsMillis
        )
        guard let envelopeFrame = makeEnvelopeFrame(type: .videoFrame, payload: payload) else { return }
        var lengthBE = UInt32(unit.data.count).bigEndian
        let lengthData = Data(bytes: &lengthBE, count: 4)
        await sendData(envelopeFrame + lengthData + unit.data, on: connection)
    }

    private func handleNewConnection(_ newConnection: NWConnection) {

        if let existing = connection {
            Task { @MainActor in
                await sendEnvelope(
                    type: .sessionEnd,
                    payload: SessionEndPayload(reason: .userClosedReader),
                    on: existing
                )
                existing.cancel()
            }
        }

        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionStateChange(state, connection: newConnection)
            }
        }
        newConnection.start(queue: .main)
    }

    private func handleConnectionStateChange(_ state: NWConnection.State, connection: NWConnection) {
        guard self.connection === connection else { return }
        switch state {
        case .ready:
            isReceiverConnected = true
            AppLogger.network.info("[Companion] Receiver connected")
            debugTrace("receiver connected")
            resetInboundParser()
            scheduleReceive(on: connection)
            Task { @MainActor in
                await sendSessionStart()
                receiverConnectedHandler?()
            }
        case .failed(let error):
            AppLogger.network.warning("[Companion] Connection failed: \(error.localizedDescription)")
            debugTrace("receiver connection failed")
            isReceiverConnected = false
            self.connection = nil
        case .cancelled:
            debugTrace("receiver connection cancelled")
            isReceiverConnected = false
            self.connection = nil
        default:
            break
        }
    }

    private func scheduleReceive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.feedInboundParser(data)
                }
                if error != nil || isComplete {
                    return
                }
                self.scheduleReceive(on: connection)
            }
        }
    }

    private func feedInboundParser(_ data: Data) {
        var remaining = data
        while !remaining.isEmpty {
            if inboundExpectedLength == nil {
                let need = 4 - inboundLengthBuffer.count
                let take = min(need, remaining.count)
                inboundLengthBuffer.append(remaining.prefix(take))
                remaining = remaining.dropFirst(take)
                if inboundLengthBuffer.count == 4 {
                    let length = inboundLengthBuffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    inboundLengthBuffer.removeAll(keepingCapacity: true)

                    guard length > 0, length < 1_000_000 else {
                        AppLogger.network.warning("[Companion] Bad inbound length \(length); ignoring connection input")
                        return
                    }
                    inboundExpectedLength = length
                }
                continue
            }

            let need = Int(inboundExpectedLength!) - inboundMessageBuffer.count
            let take = min(need, remaining.count)
            inboundMessageBuffer.append(remaining.prefix(take))
            remaining = remaining.dropFirst(take)
            if inboundMessageBuffer.count == Int(inboundExpectedLength!) {
                handleInboundEnvelope(inboundMessageBuffer)
                inboundMessageBuffer.removeAll(keepingCapacity: true)
                inboundExpectedLength = nil
            }
        }
    }

    private func handleInboundEnvelope(_ data: Data) {
        do {
            let envelope = try JSONDecoder().decode(CompanionMessageEnvelope.self, from: data)
            switch envelope.type {
            case .pageCommand:
                let payload = try JSONDecoder().decode(PageCommandPayload.self, from: envelope.payloadJSON)
                pageCommandHandler?(payload.direction)
            case .viewportInfo:
                let payload = try JSONDecoder().decode(ViewportInfoPayload.self, from: envelope.payloadJSON)
                receiverViewport = payload
                AppLogger.network.info("[Companion] Receiver viewport: \(Int(payload.width))×\(Int(payload.height))")
                viewportInfoHandler?(payload)
            case .readAloudCommand:
                let payload = try JSONDecoder().decode(ReadAloudCommandPayload.self, from: envelope.payloadJSON)
                readAloudCommandHandler?(payload.action)
            case .ping:

                if let connection {
                    Task { await sendEnvelope(type: .pong, payload: EmptyPayload(), on: connection) }
                }
            default:

                break
            }
        } catch {
            AppLogger.network.warning("[Companion] Inbound decode failed: \(error.localizedDescription)")
        }
    }

    private func resetInboundParser() {
        inboundLengthBuffer.removeAll(keepingCapacity: true)
        inboundMessageBuffer.removeAll(keepingCapacity: true)
        inboundExpectedLength = nil
    }

    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                AppLogger.network.info("[Companion] Listener ready on port \(port)")
            }
        case .failed(let error):
            AppLogger.network.warning("[Companion] Listener failed: \(error.localizedDescription)")
            Task { await stop(reason: .error) }
        default:
            break
        }
    }

    private func sendSessionStart() async {
        guard let connection, let context = currentSession else { return }
        let payload = SessionStartPayload(
            bookTitle: context.bookTitle,
            bookStableId: context.bookStableId,
            deviceName: deviceDisplayName(),
            pageSize: PageSize(
                width: Double(context.pageSize?.width ?? 0),
                height: Double(context.pageSize?.height ?? 0)
            ),
            hasMediaOverlay: context.hasMediaOverlay
        )
        await sendEnvelope(type: .sessionStart, payload: payload, on: connection)
    }

    private func sendEnvelope<T: Encodable>(type: CompanionMessageType, payload: T, on connection: NWConnection) async {
        guard let frame = makeEnvelopeFrame(type: type, payload: payload) else { return }
        await sendData(frame, on: connection)
    }

    private func makeEnvelopeFrame<T: Encodable>(type: CompanionMessageType, payload: T) -> Data? {
        do {
            let payloadJSON = try JSONEncoder().encode(payload)
            let envelope = CompanionMessageEnvelope(type: type, payloadJSON: payloadJSON)
            let envelopeData = try JSONEncoder().encode(envelope)
            var lengthBE = UInt32(envelopeData.count).bigEndian
            return Data(bytes: &lengthBE, count: 4) + envelopeData
        } catch {
            AppLogger.network.warning("[Companion] Encode failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func sendData(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        AppLogger.network.warning("[Companion] Send failed: \(error.localizedDescription)")
                    }
                    continuation.resume()
                }
            )
        }
    }

    private func makeTxtRecord(for context: SessionContext) -> NWTXTRecord {
        var record = NWTXTRecord()
        record[CompanionService.txtRecordKeys.bookTitle] = context.bookTitle
        record[CompanionService.txtRecordKeys.deviceName] = deviceDisplayName()
        record[CompanionService.txtRecordKeys.protocolVersion] = "1"
        return record
    }

    private func deviceDisplayName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iPhone"
        #endif
    }
}
