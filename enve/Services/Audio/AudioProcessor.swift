import AVFoundation
import Accelerate
import AudioToolbox
import Combine
import Foundation
import MediaToolbox
import SwiftUI
import os

final class AudioProcessor: ObservableObject {
    static let shared = AudioProcessor()

    @Published var bands: [EqualizerBand] = EqualizerPreset.flat.bands
    @Published private(set) var volumeLevelingStrength: VolumeLevelingStrength

    @AppStorage("voiceBoostMode") var voiceBoostMode: VoiceBoostMode = .off {
        didSet { updateVoiceBoost(voiceBoostMode) }
    }

    @AppStorage("currentEQPresetID") var currentEQPresetID: String = "flat" {
        didSet { applyPreset(id: currentEQPresetID) }
    }

    @Published var globalGain: Float = 1.0 {
        didSet {
            let value = globalGain
            globalGainStorage.withLock { $0 = value }
        }
    }

    fileprivate let globalGainStorage = OSAllocatedUnfairLock<Float>(initialState: 1.0)

    nonisolated(unsafe) fileprivate var filtersStorage: [BiquadFilter] = []
    nonisolated(unsafe) fileprivate var volumeLevelerStorage: VolumeLeveler?
    nonisolated(unsafe) fileprivate var sampleRateStorage: Double = 44100
    nonisolated(unsafe) fileprivate var channelsStorage: Int = 2
    nonisolated fileprivate let filterStateLock = NSLock()

    private let rebuildQueue = DispatchQueue(label: "enve.audioProcessor.rebuild", qos: .userInitiated)

    init() {
        volumeLevelingStrength =
            LibraryDisplayPreferencesStore.shared
            .loadPreferences()
            .volumeLevelingStrength
    }

    @MainActor
    func updateBands(_ newBands: [EqualizerBand]) {
        self.bands = newBands
        Task { @MainActor in scheduleRebuildFiltersAsync() }
    }

    @MainActor
    func updateVoiceBoost(_ mode: VoiceBoostMode) {
        _ = mode
        Task { @MainActor in scheduleRebuildFiltersAsync() }
    }

    func setVolumeLevelingStrength(_ strength: VolumeLevelingStrength) {
        guard strength != volumeLevelingStrength else { return }
        volumeLevelingStrength = strength

        var preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        preferences.volumeLevelingStrength = strength
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
        scheduleRebuildFiltersAsync()
    }

    @MainActor
    func applyPreset(id: String) {
        guard id != "custom" else { return }
        if let preset = EqualizerPreset.allPresets.first(where: { $0.id == id }) {
            updateBands(preset.bands)
        }
    }

    nonisolated func updateProcessingFormat(sampleRate: Double, channels: Int) {
        filterStateLock.lock()
        sampleRateStorage = sampleRate
        channelsStorage = channels
        filterStateLock.unlock()
        Task { @MainActor in
            scheduleRebuildFiltersAsync()
        }
    }

    @MainActor
    private func scheduleRebuildFiltersAsync() {
        let bandsSnapshot = bands
        let voiceBoostSnapshot = voiceBoostMode
        let levelingStrengthSnapshot = volumeLevelingStrength
        let (sampleRateSnapshot, channelsSnapshot) = readFormatSnapshot()

        scheduleRebuildFilters(
            bandsSnapshot: bandsSnapshot,
            voiceBoostSnapshot: voiceBoostSnapshot,
            levelingStrengthSnapshot: levelingStrengthSnapshot,
            sampleRateSnapshot: sampleRateSnapshot,
            channelsSnapshot: channelsSnapshot
        )
    }

    nonisolated private func readFormatSnapshot() -> (sampleRate: Double, channels: Int) {
        filterStateLock.lock()
        defer { filterStateLock.unlock() }
        return (sampleRateStorage, channelsStorage)
    }

    nonisolated private func scheduleRebuildFilters(
        bandsSnapshot: [EqualizerBand],
        voiceBoostSnapshot: VoiceBoostMode,
        levelingStrengthSnapshot: VolumeLevelingStrength,
        sampleRateSnapshot: Double,
        channelsSnapshot: Int
    ) {
        rebuildQueue.async { [weak self] in
            guard let self else { return }
            let newFilters = self.buildFilters(
                bands: bandsSnapshot,
                voiceBoostMode: voiceBoostSnapshot,
                sampleRate: sampleRateSnapshot,
                channels: channelsSnapshot
            )
            let newVolumeLeveler = levelingStrengthSnapshot.parameters.map {
                VolumeLeveler(
                    parameters: $0,
                    sampleRate: sampleRateSnapshot,
                    channels: channelsSnapshot
                )
            }

            self.filterStateLock.lock()
            self.filtersStorage = newFilters
            self.volumeLevelerStorage = newVolumeLeveler
            self.filterStateLock.unlock()
        }
    }

    nonisolated private func buildFilters(
        bands: [EqualizerBand],
        voiceBoostMode: VoiceBoostMode,
        sampleRate: Double,
        channels: Int
    ) -> [BiquadFilter] {
        var newFilters: [BiquadFilter] = []

        for band in bands {
            if band.gain != 0 {
                newFilters.append(
                    BiquadFilter.peaking(frequency: Double(band.frequency), gain: Double(band.gain), q: 1.0, sampleRate: sampleRate)
                )
            }
        }

        switch voiceBoostMode {
        case .off: break
        case .low:
            newFilters.append(BiquadFilter.highPass(frequency: 150, q: 0.707, sampleRate: sampleRate))
            newFilters.append(BiquadFilter.peaking(frequency: 2000, gain: 3.0, q: 0.5, sampleRate: sampleRate))
        case .medium:
            newFilters.append(BiquadFilter.highPass(frequency: 200, q: 0.707, sampleRate: sampleRate))
            newFilters.append(BiquadFilter.peaking(frequency: 2500, gain: 6.0, q: 0.4, sampleRate: sampleRate))
        case .high:
            newFilters.append(BiquadFilter.highPass(frequency: 250, q: 0.707, sampleRate: sampleRate))
            newFilters.append(BiquadFilter.peaking(frequency: 3000, gain: 9.0, q: 0.3, sampleRate: sampleRate))
        }

        for filter in newFilters {
            filter.setupChannels(channels)
        }

        return newFilters
    }

    nonisolated func createTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: nil,
            process: tapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return status == noErr ? tap : nil
    }
}

nonisolated final class VolumeLeveler {
    private let thresholdDB: Float
    private let ratio: Float
    private let makeupGainDB: Float
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private var envelopes: [Float]
    private var gains: [Float]

    init(parameters: VolumeLevelingParameters, sampleRate: Double, channels: Int) {
        thresholdDB = parameters.thresholdDB
        ratio = max(parameters.ratio, 1)
        makeupGainDB = parameters.makeupGainDB

        let rate = Float(max(sampleRate, 1))
        attackCoefficient = exp(-1 / max(rate * parameters.attack, 1))
        releaseCoefficient = exp(-1 / max(rate * parameters.release, 1))
        envelopes = Array(repeating: 0, count: max(channels, 1))
        gains = Array(repeating: 1, count: max(channels, 1))
    }

    func process(buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard count > 0 else { return }
        let channelIndex = min(max(channel, 0), envelopes.count - 1)
        var envelope = envelopes[channelIndex]
        var gain = gains[channelIndex]

        for index in 0..<count {
            let input = buffer[index]
            let magnitude = abs(input)
            let envelopeCoefficient = magnitude > envelope ? attackCoefficient : releaseCoefficient
            envelope = envelopeCoefficient * envelope + (1 - envelopeCoefficient) * magnitude

            let levelDB = 20 * log10(max(envelope, 0.000_001))
            let compressedDB =
                levelDB > thresholdDB
                ? thresholdDB + (levelDB - thresholdDB) / ratio
                : levelDB
            let desiredGain = pow(10, (compressedDB - levelDB + makeupGainDB) / 20)
            let gainCoefficient = desiredGain < gain ? attackCoefficient : releaseCoefficient
            gain = gainCoefficient * gain + (1 - gainCoefficient) * desiredGain

            buffer[index] = min(max(input * gain, -0.99), 0.99)
        }

        envelopes[channelIndex] = envelope
        gains[channelIndex] = gain
    }
}

nonisolated class BiquadFilter {
    var b0, b1, b2, a1, a2: Double
    var channelStates: [[Double]] = []

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    func setupChannels(_ count: Int) {
        channelStates = Array(repeating: [0.0, 0.0], count: count)
    }

    static func peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> BiquadFilter {
        let a = pow(10, gain / 40.0)
        let w0 = 2.0 * .pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cs = cos(w0)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cs
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cs
        let a2 = 1.0 - alpha / a

        return BiquadFilter(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> BiquadFilter {
        let w0 = 2.0 * .pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cs = cos(w0)

        let b0 = (1.0 + cs) / 2.0
        let b1 = -(1.0 + cs)
        let b2 = (1.0 + cs) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cs
        let a2 = 1.0 - alpha

        return BiquadFilter(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    func process(buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard channel < channelStates.count else { return }
        var state = channelStates[channel]

        for i in 0..<count {
            let x = Double(buffer[i])
            let y = b0 * x + b1 * state[0] + b2 * state[1] - a1 * state[0] - a2 * state[1]
            state[1] = state[0]
            state[0] = x
            buffer[i] = Float(y)
        }
        channelStates[channel] = state
    }
}

nonisolated private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let selfRef = Unmanaged<AudioProcessor>.fromOpaque(storage).takeUnretainedValue()
    selfRef.updateProcessingFormat(
        sampleRate: processingFormat.pointee.mSampleRate,
        channels: Int(processingFormat.pointee.mChannelsPerFrame)
    )
}

nonisolated private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {

    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    if status != noErr { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let selfRef = Unmanaged<AudioProcessor>.fromOpaque(storage).takeUnretainedValue()

    let gain = selfRef.globalGainStorage.withLock { $0 }
    selfRef.filterStateLock.lock()
    let currentFilters = selfRef.filtersStorage
    let volumeLeveler = selfRef.volumeLevelerStorage
    selfRef.filterStateLock.unlock()
    let frameCount = Int(numberFrames)

    let bufferCount = Int(bufferListInOut.pointee.mNumberBuffers)
    withUnsafeMutablePointer(to: &bufferListInOut.pointee.mBuffers) { firstBuffer in
        let buffers = UnsafeMutableRawPointer(firstBuffer).assumingMemoryBound(to: AudioBuffer.self)
        for channel in 0..<bufferCount {
            let buffer = buffers[channel]
            if let data = buffer.mData {
                let floatData = data.assumingMemoryBound(to: Float.self)

                for filter in currentFilters {
                    filter.process(buffer: floatData, count: frameCount, channel: channel)
                }

                volumeLeveler?.process(buffer: floatData, count: frameCount, channel: channel)

                if gain != 1.0 {
                    var vGain = gain
                    vDSP_vsmul(floatData, 1, &vGain, floatData, 1, vDSP_Length(numberFrames))
                }
            }
        }
    }
}

nonisolated private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

nonisolated private func tapFinalize(tap: MTAudioProcessingTap) {
}
