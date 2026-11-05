#if os(iOS)
import AudioToolbox
import AVFoundation
import Foundation
import os

nonisolated enum PassageAudioWindow {
    static func extract(track: PassageTrack, start: TimeInterval, end: TimeInterval) async throws -> URL {
        let source = PassageAudioSource(url: track.url, headers: track.headers, networkSession: track.networkSession)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try source.writeWindow(start: start, duration: end - start)
            }.value
        } onCancel: { source.cancel() }
    }
}

nonisolated private final class PassageAudioSource: Sendable {
    private struct State {
        var cancelled = false
        var active: Task<Void, Never>?
        var size: Int64 = -1
        var tag: String?
        var blockStart: Int64 = -1
        var block = Data()
        var error: Error?
    }
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(url: URL, headers: [String: String], networkSession: URLSession?) {
        self.url = url
        self.headers = headers
        let configuration = networkSession?.configuration ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: networkSession?.delegate, delegateQueue: nil)
    }

    func cancel() {
        state.withLock { value in value.cancelled = true; value.active?.cancel() }
        session.invalidateAndCancel()
    }

    private func check() throws {
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
    }

    func writeWindow(start: TimeInterval, duration: TimeInterval) throws -> URL {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 90 else { throw URLError(.badURL) }
        defer { session.invalidateAndCancel() }
        _ = try read(position: 0, count: 1)
        var audioFile: AudioFileID?
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let opened = AudioFileOpenWithCallbacks(pointer, { context, position, count, buffer, actual in
            let source = Unmanaged<PassageAudioSource>.fromOpaque(context).takeUnretainedValue()
            do {
                let data = try source.read(position: position, count: Int(count))
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                actual.pointee = UInt32(data.count)
                return noErr
            } catch {
                source.state.withLock { $0.error = error }
                actual.pointee = 0
                return kAudioFileUnspecifiedError
            }
        }, nil, { context in
            Unmanaged<PassageAudioSource>.fromOpaque(context).takeUnretainedValue().state.withLock { $0.size }
        }, nil, 0, &audioFile)
        try validate(opened)
        guard let audioFile else { throw URLError(.cannotDecodeContentData) }
        defer { AudioFileClose(audioFile) }
        var extended: ExtAudioFileRef?
        try validate(ExtAudioFileWrapAudioFileID(audioFile, false, &extended))
        guard let extended else { throw URLError(.cannotDecodeContentData) }
        defer { ExtAudioFileDispose(extended) }
        var original = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try validate(ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileDataFormat, &size, &original))
        var output = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try validate(ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &output))
        guard let frame = Int64(exactly: (start * original.mSampleRate).rounded(.down)), frame >= 0 else { throw URLError(.cannotDecodeContentData) }
        try validate(ExtAudioFileSeek(extended, frame))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("passage-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: destination, settings: format.settings)
            var remaining = Int((duration * 16_000).rounded())
            while remaining > 0 {
                try check()
                var frames = UInt32(min(remaining, 4_096))
                buffer.frameLength = frames
                try validate(ExtAudioFileRead(extended, &frames, buffer.mutableAudioBufferList))
                if frames == 0 { break }
                buffer.frameLength = frames
                try file.write(from: buffer)
                remaining -= Int(frames)
            }
            try check()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func validate(_ status: OSStatus) throws {
        try check()
        if let error = state.withLock({ $0.error }) { throw error }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func read(position: Int64, count: Int) throws -> Data {
        guard position >= 0, count >= 0, count <= 32 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        while data.count < count {
            let chunk = try readChunk(position: position + Int64(data.count), count: count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    private func readChunk(position: Int64, count: Int) throws -> Data {
        try check()
        let cached = state.withLock { value -> Data? in
            if position >= value.size, value.size >= 0 { return Data() }
            let offset = position - value.blockStart
            guard offset >= 0, offset < value.block.count else { return nil }
            let start = Int(offset)
            return value.block.subdata(in: start..<min(value.block.count, start + count))
        }
        if let cached { return cached }
        let from = position
        guard position <= Int64.max - 262_143 else { throw URLError(.badServerResponse) }
        let to = position + 262_143
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let currentTag = state.withLock { $0.tag }
        if let currentTag { request.setValue(currentTag, forHTTPHeaderField: "If-Range") }
        let result = OSAllocatedUnfairLock<Result<Data, Error>?>(initialState: nil)
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached { [session, state] in
            defer { semaphore.signal() }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                    let range = http.value(forHTTPHeaderField: "Content-Range"),
                    let slash = range.lastIndex(of: "/"), let total = Int64(range[range.index(after: slash)...]),
                    let dash = range.firstIndex(of: "-"), range.hasPrefix("bytes "),
                    let lower = Int64(range.dropFirst(6).prefix(upTo: dash)),
                    let upper = Int64(range[range.index(after: dash)..<slash]),
                    lower == from, upper >= lower, upper <= to, total > upper
                else { throw URLError(.badServerResponse) }
                let tag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
                guard state.withLock({ value in
                    (value.size < 0 || value.size == total) && (value.tag == nil || value.tag == tag)
                }) else { throw URLError(.resourceUnavailable) }
                var data = Data()
                data.reserveCapacity(Int(upper - lower + 1))
                for try await byte in bytes {
                    if data.count % 16_384 == 0 { try Task.checkCancellation() }
                    guard data.count < upper - lower + 1 else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                guard data.count == upper - lower + 1 else { throw URLError(.badServerResponse) }
                let payload = data
                state.withLock { value in
                    value.size = total; value.tag = tag; value.blockStart = from; value.block = payload
                }
                result.withLock { $0 = .success(payload) }
            } catch { result.withLock { $0 = .failure(error) } }
        }
        state.withLock { value in value.active = task; if value.cancelled { task.cancel() } }
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut { try check() }
        state.withLock { $0.active = nil }
        try check()
        let data = try result.withLock { try $0!.get() }
        return data.prefix(count)
    }
}
#endif
