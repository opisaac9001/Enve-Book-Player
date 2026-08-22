import AVFoundation
import Accelerate
import AudioToolbox
import Logging

final class EQTapProcessor {

    private var bands: [Float] = Array(repeating: 0, count: 10)

    private let frequencies: [Float] = AppConstants.Audio.eqBandFrequencies.map { Float($0) }

    private let lock = NSLock()

    var filters: [EQBiquadFilter] = []

    init() {
        filters = frequencies.map { freq in
            EQBiquadFilter(
                frequency: freq,
                gain: 0,
                q: Float(AppConstants.Audio.defaultBandQ),
                sampleRate: Float(AppConstants.Audio.defaultSampleRate)
            )
        }
    }

    func setBands(_ newBands: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        bands = newBands

        for (index, gain) in bands.enumerated() {
            if index < filters.count {
                filters[index].setGain(gain)
            }
        }

        AppLogger.network.info("Bands updated: \(bands.map { String(format: "%.1f", $0) })")
    }

    func attachTap(to item: AVPlayerItem) {
        let asset = item.asset

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let audioTrack = tracks.first else {
                    AppLogger.network.info("No audio track found in asset")
                    return
                }

                let audioMix = self.createAudioMix(for: audioTrack)

                await MainActor.run {
                    item.audioMix = audioMix
                    AppLogger.network.info("Tap attached to player item")
                }
            } catch {
                AppLogger.network.error("Failed to load audio tracks: \(error)")
            }
        }
    }

    @_optimize(none)
    private func createAudioMix(for track: AVAssetTrack) -> AVMutableAudioMix {
        let audioMix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: track)

        params.setVolume(1.0, at: .zero)
        AppLogger.network.warning("EQ tap disabled in createAudioMix fallback")

        audioMix.inputParameters = [params]
        return audioMix
    }
}

private class TapContext {
    var processor: EQTapProcessor
    var format: AudioStreamBasicDescription?

    init(processor: EQTapProcessor) {
        self.processor = processor
    }
}

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    guard let clientInfo = clientInfo else { return }

    let processor = Unmanaged<EQTapProcessor>.fromOpaque(clientInfo).takeUnretainedValue()
    let context = TapContext(processor: processor)
    tapStorageOut.pointee = Unmanaged.passRetained(context).toOpaque()

    AppLogger.network.info("Tap initialized")
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<TapContext>.fromOpaque(storage).release()
    AppLogger.network.info("Tap finalized")
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    context.format = processingFormat.pointee

    let sampleRate = Float(processingFormat.pointee.mSampleRate)
    for filter in context.processor.filters {
        filter.sampleRate = sampleRate
        filter.recalculate()
    }

    AppLogger.network.info(
        "Tap prepared: \(processingFormat.pointee.mSampleRate) Hz, \(processingFormat.pointee.mChannelsPerFrame) channels"
    )
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    AppLogger.network.info("Tap unprepared")
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else {
        AppLogger.network.error("Failed to get source audio: \(status)")
        return
    }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()

    if let format = context.format, (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 {
        return
    }

    let bufferCount = Int(bufferListInOut.pointee.mNumberBuffers)
    withUnsafeMutablePointer(to: &bufferListInOut.pointee.mBuffers) { firstBuffer in
        let buffers = UnsafeMutableRawPointer(firstBuffer).assumingMemoryBound(to: AudioBuffer.self)
        for channel in 0..<bufferCount {
            let buffer = buffers[channel]
            guard let data = buffer.mData else { continue }

            let floatBuffer = data.assumingMemoryBound(to: Float.self)
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

            for filter in context.processor.filters {
                filter.process(floatBuffer, frameCount: frameCount, channelIndex: channel)
            }
        }
    }
}

class EQBiquadFilter {
    var frequency: Float
    var gain: Float
    var q: Float
    var sampleRate: Float

    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0

    private var x1: [Float] = Array(repeating: 0, count: 8)
    private var x2: [Float] = Array(repeating: 0, count: 8)
    private var y1: [Float] = Array(repeating: 0, count: 8)
    private var y2: [Float] = Array(repeating: 0, count: 8)

    init(frequency: Float, gain: Float, q: Float, sampleRate: Float) {
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.sampleRate = sampleRate
        recalculate()
    }

    func setGain(_ newGain: Float) {
        gain = newGain
        recalculate()
    }

    func recalculate() {

        if sampleRate <= 0 {
            b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            return
        }

        let nyquist = sampleRate * 0.5
        if frequency >= nyquist * 0.98 {
            b0 = 1
            b1 = 0
            b2 = 0
            a1 = 0
            a2 = 0
            return
        }

        if abs(gain) < 0.01 {
            b0 = 1
            b1 = 0
            b2 = 0
            a1 = 0
            a2 = 0
            return
        }

        let A = pow(10, gain / 40)
        let omega = 2 * Float.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * q)

        let a0 = 1 + alpha / A
        b0 = (1 + alpha * A) / a0
        b1 = (-2 * cosOmega) / a0
        b2 = (1 - alpha * A) / a0
        a1 = (-2 * cosOmega) / a0
        a2 = (1 - alpha / A) / a0
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int, channelIndex: Int) {
        if abs(gain) < 0.01 { return }

        let ch = min(max(channelIndex, 0), 7)

        var lx1 = x1[ch]
        var lx2 = x2[ch]
        var ly1 = y1[ch]
        var ly2 = y2[ch]

        for i in 0..<frameCount {
            let x0 = buffer[i]
            var y0 = b0 * x0 + b1 * lx1 + b2 * lx2 - a1 * ly1 - a2 * ly2

            if !y0.isFinite || abs(y0) < 1e-15 {
                y0 = 0
            }

            lx2 = lx1
            lx1 = x0
            ly2 = ly1
            ly1 = y0

            buffer[i] = y0
        }

        x1[ch] = lx1
        x2[ch] = lx2
        y1[ch] = ly1
        y2[ch] = ly2

    }

    func clearState() {
        x1 = Array(repeating: 0, count: 8)
        x2 = Array(repeating: 0, count: 8)
        y1 = Array(repeating: 0, count: 8)
        y2 = Array(repeating: 0, count: 8)
    }
}
