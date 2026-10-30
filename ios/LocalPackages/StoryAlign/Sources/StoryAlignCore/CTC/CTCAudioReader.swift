@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum CTCAudioReader {
    static func read(url: URL, start: Double, duration: Double) async throws -> [Float] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw StoryAlignError("The audiobook has no readable audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StoryAlignError("The audiobook cannot be decoded for alignment.") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16_000), duration: CMTime(seconds: duration, preferredTimescale: 16_000))
        guard reader.startReading() else { throw reader.error ?? StoryAlignError("Audio decoding could not start.") }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        let maximumSamples = Int(ceil(duration * 16_000))
        samples.reserveCapacity(maximumSamples)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  stream.pointee.mSampleRate == 16_000, stream.pointee.mChannelsPerFrame == 1,
                  let block = CMSampleBufferGetDataBuffer(buffer) else {
                throw StoryAlignError("Audio decoding returned an unexpected sample format.")
            }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard timestamp.isFinite else { throw StoryAlignError("Audio decoding returned an invalid timestamp.") }
            let position = Int(((timestamp - start) * 16_000).rounded())
            let placement = placement(bufferOffset: position, sampleCount: count, existing: samples.count, limit: maximumSamples)
            if placement.padding > 0 {
                samples.append(contentsOf: repeatElement(0, count: placement.padding))
            }
            let skip = placement.skip
            let take = placement.take
            if take > 0 {
                var decoded = [Float](repeating: 0, count: take)
                let status = decoded.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: skip * MemoryLayout<Float>.size, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw StoryAlignError("Could not read decoded audio samples.") }
                samples.append(contentsOf: decoded)
            }
            if samples.count >= maximumSamples { break }
        }
        if reader.status == .failed { throw reader.error ?? StoryAlignError("Audio decoding failed.") }
        return samples
    }

    static func placement(bufferOffset: Int, sampleCount: Int, existing: Int, limit: Int) -> (padding: Int, skip: Int, take: Int) {
        let padding = min(limit - existing, max(0, bufferOffset - existing))
        let filled = existing + padding
        let skip = max(0, filled - bufferOffset)
        let take = min(limit - filled, max(0, sampleCount - skip))
        return (padding, skip, take)
    }
}
