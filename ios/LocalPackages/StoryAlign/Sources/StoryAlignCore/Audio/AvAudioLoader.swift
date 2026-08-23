//
// AvAudioLoader.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters


import Foundation
import AVFoundation


struct AvAudioLoader : AudioLoader {
    let session: AlignmentSession

    func getChapters(from url: URL) async throws -> [ChapterInfo] {
        let asset = AVURLAsset(url: url)
        
        if url.pathExtension == "mp3" {
            let title = await getTitleStringFromMp3(url: url) ?? url.lastPathComponent
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            guard seconds.isFinite && seconds > 0 else {
                logger.log( .warn, "Cannot process mp3 \(title): No duration.")
                return []
            }

            let chapter = ChapterInfo(start: 0, end: seconds, title: title)
            return [chapter]
        }
        
        
        let locales = try await asset.load(.availableChapterLocales)
        if let locale = locales.first {
            let groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: []
            )

            var chapters:[ChapterInfo] = []
            for group in groups {
                let start = group.timeRange.start.seconds
                let duration = group.timeRange.duration.seconds
                let end = start + duration

                let title:String? = try await {
                    guard let item = group.items.first(where: { $0.commonKey == .commonKeyTitle }) else {
                        return nil
                    }
                    let retTitle = try await item.load(.stringValue)
                    return retTitle
                }()

                chapters.append( ChapterInfo( start: start, end: end, title:title ) )
            }
            if !chapters.isEmpty {
                return chapters
            }
        }

        // No chapter metadata: split into fixed-length windows. StoryAlign chunks per chapter so
        // each unit decodes and transcribes independently (and in parallel). A single whole-file
        // "chapter" would decode the entire book into memory at once and transcribe it as one
        // sequential stream — multiple GB of RAM and no parallelism for a long audiobook. Each
        // window becomes its own audio file in the output EPUB, exactly like a real chapter.
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite && seconds > 0 else {
            logger.log( .warn, "Cannot process \(url.lastPathComponent): no chapters and no duration.")
            return []
        }
        let windowLength: TimeInterval = 900
        let title = url.deletingPathExtension().lastPathComponent
        var windows: [ChapterInfo] = []
        var windowStart = 0.0
        while windowStart < seconds {
            let windowEnd = min(windowStart + windowLength, seconds)
            windows.append( ChapterInfo(start: windowStart, end: windowEnd, title: title) )
            windowStart = windowEnd
        }
        logger.log(.info, "No chapters in \(url.lastPathComponent); split into \(windows.count) window(s) of \(Int(windowLength))s")
        return windows
    }
    
    func extractAudio(from url: URL, using audioFileInfo: AudioFile) async throws  {
        if url.pathExtension == "mp3" {
            try FileManager.default.copyItem(at: url, to: audioFileInfo.filePath)
            return
        }
        
        let asset = AVURLAsset(url: url)
        
        let start = CMTime(seconds: audioFileInfo.startTmeInterval, preferredTimescale: 600)
        let end = CMTime(seconds: audioFileInfo.endTmeInterval, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, end: end)
        
        if audioFileInfo.index > 0 {
            let composition = AVMutableComposition()
            
            if let srcAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let dstAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                
                try dstAudioTrack.insertTimeRange(timeRange, of: srcAudioTrack, at: .zero)
                
                if let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) {
                    exportSession.timeRange = CMTimeRange(start: .zero, duration: timeRange.duration)
                    try await exportSession.export( to: audioFileInfo.filePath,  as: .m4a )
                    return
                }
            }
        }
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw StoryAlignError( "Error extracting audio -- could not create export session" )
        }
        
        exportSession.timeRange = timeRange
        try await exportSession.export( to: audioFileInfo.filePath,  as: .m4a )
    }
     
    func decode( from fileURL: URL ) async throws -> [Float] {
        return try load16kMonoPCM_viaAVAudioFile(fileURL)
    }
    
    func outputPathExtension(from url: URL) async throws -> String {
        if url.pathExtension == "mp3" {
            return url.pathExtension
        }
        return "m4a"
    }
}

extension AvAudioLoader {
    func load16kMonoPCM_viaAVAudioFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)

        let inFmt  = file.processingFormat
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioLoaderPCM.sampleRate,
            //channels: inFmt.channelCount,
            channels:  AVAudioChannelCount( AudioLoaderPCM.channels ),
            interleaved: false
        )!
        let converter = AVAudioConverter(from: inFmt, to: outFmt)!
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        _ = converter.sampleRateConverterQuality
        _ = converter.sampleRateConverterAlgorithm

        let chunkFrames: AVAudioFrameCount = 8192
        var out: [Float] = []

        /*
        let inBuf = AVAudioPCMBuffer(
            pcmFormat: inFmt,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: inBuf)
        
        
        final class InputState: @unchecked Sendable {
            let fmt: AVAudioFormat
            let channels: [UnsafePointer<Float>]
            let buf: AVAudioPCMBuffer
            var pos: AVAudioFramePosition = 0

            init(fmt: AVAudioFormat, buf: AVAudioPCMBuffer) {
                self.fmt = fmt
                self.buf = buf
                let fcd = self.buf.floatChannelData!
                let n = Int(fmt.channelCount)
                self.channels = (0..<n).map { UnsafePointer(fcd[$0]) }
            }
        }

        let state = InputState(fmt: inFmt, buf: inBuf)
        let totalInputFrames = AVAudioFramePosition(inBuf.frameLength)

        let inputBlock:AVAudioConverterInputBlock = { inNumPackets, outStatus in
            let framesLeft = totalInputFrames - state.pos
            guard framesLeft > 0 else { outStatus.pointee = .endOfStream; return nil }
            let n = min(AVAudioFrameCount(framesLeft), inNumPackets)
            let chunk = AVAudioPCMBuffer(pcmFormat: state.fmt, frameCapacity: n)!
            chunk.frameLength = n
            for ch in 0..<state.channels.count {
                let src = state.channels[ch].advanced(by: Int(state.pos))
                let dst = chunk.floatChannelData![ch]
                dst.update(from: src, count: Int(n))
            }
            state.pos &+= AVAudioFramePosition(n)
            outStatus.pointee = .haveData
            return chunk
        }
         */
        
        final class InputBlockState: @unchecked Sendable {
            let file: AVAudioFile
            let inBuf: AVAudioPCMBuffer
            var hitEOF = false
            
            init(file: AVAudioFile, inFmt: AVAudioFormat, chunkFrames: AVAudioFrameCount) {
                self.file = file
                self.inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunkFrames)!
            }
        }
        
        let state = InputBlockState(file: file, inFmt: inFmt, chunkFrames: chunkFrames)
        
        let inputBlock: AVAudioConverterInputBlock = { requestedFrames, outStatus in
            if state.hitEOF {
                outStatus.pointee = .endOfStream
                return nil
            }
            
            let toRead = min(chunkFrames, requestedFrames)
            state.inBuf.frameLength = 0
            try? file.read(into: state.inBuf, frameCount: toRead)
            
            if state.inBuf.frameLength == 0 {
                state.hitEOF = true
                outStatus.pointee = .endOfStream
                return nil
            }
            
            outStatus.pointee = .haveData
            return state.inBuf
        }
        

        var error: NSError?
        converter.reset()

        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunkFrames)!
            outBuf.frameLength = chunkFrames
            if let p = outBuf.floatChannelData?[0] {
                p.initialize(repeating: 0, count: Int(chunkFrames))
            }
            outBuf.frameLength = 0
            
            let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
            
            let n = Int(outBuf.frameLength)
            if n > 0 {
                let ptr = outBuf.floatChannelData![0]
                out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
            }

            if status == .haveData { continue }
            if status == .inputRanDry { continue }
            if status == .endOfStream { break }
            throw error ?? StoryAlignError( "AudioConversion error")
        }
        
        return out
    }
    
    func getTitleStringFromMp3(url: URL) async -> String? {
        let audioAsset = AVURLAsset(url: url)
        do {
            let commonMetadataItems = try await audioAsset.load(.commonMetadata)

            let titleMetadataItem = AVMetadataItem.metadataItems(
                from: commonMetadataItems,
                filteredByIdentifier: .commonIdentifierTitle
            ).first

            if let titleString = try await titleMetadataItem?.load(.stringValue),
               !titleString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return titleString
            }

            return nil
        } catch {
            return nil
        }
    }
}
