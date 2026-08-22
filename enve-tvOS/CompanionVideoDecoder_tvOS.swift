import AVFoundation
import CoreMedia
import Foundation
import Logging

@MainActor
final class CompanionVideoDecoder_tvOS {
    let displayLayer = AVSampleBufferDisplayLayer()

    private var formatDescription: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var frameIndex: Int64 = 0

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    func reset() {
        displayLayer.flushAndRemoveImage()
        formatDescription = nil
        sps = nil
        pps = nil
        frameIndex = 0
    }

    func decode(accessUnit: Data, isKeyframe: Bool, ptsMillis: Int64) {
        let nalUnits = Self.splitAnnexB(accessUnit)
        guard !nalUnits.isEmpty else { return }

        var pictureNALs: [Data] = []
        for nal in nalUnits {
            guard let first = nal.first else { continue }
            let nalType = first & 0x1F
            switch nalType {
            case 7: sps = nal
            case 8: pps = nal
            case 9: break
            default: pictureNALs.append(nal)
            }
        }

        if formatDescription == nil, let sps, let pps {
            formatDescription = Self.makeFormatDescription(sps: sps, pps: pps)
        }

        guard let formatDescription, !pictureNALs.isEmpty else { return }
        guard
            let sampleBuffer = Self.makeSampleBuffer(
                pictureNALs: pictureNALs,
                formatDescription: formatDescription,
                ptsMillis: ptsMillis
            )
        else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    private static func splitAnnexB(_ data: Data) -> [Data] {
        var nalUnits: [Data] = []
        let bytes = [UInt8](data)
        var index = 0
        var nalStart = -1

        func startCodeLength(at i: Int) -> Int {
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                return 4
            }
            if i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                return 3
            }
            return 0
        }

        while index < bytes.count {
            let scLen = startCodeLength(at: index)
            if scLen > 0 {
                if nalStart >= 0 && index > nalStart {
                    nalUnits.append(Data(bytes[nalStart..<index]))
                }
                index += scLen
                nalStart = index
            } else {
                index += 1
            }
        }
        if nalStart >= 0 && nalStart < bytes.count {
            nalUnits.append(Data(bytes[nalStart..<bytes.count]))
        }
        return nalUnits
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress!
                let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }
        guard status == noErr else {
            AppLogger.network.error("[CompanionVideo] format description create failed (\(status))")
            return nil
        }
        return formatDescription
    }

    private static func makeSampleBuffer(
        pictureNALs: [Data],
        formatDescription: CMFormatDescription,
        ptsMillis: Int64
    ) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in pictureNALs {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let avccBytes = [UInt8](avcc)
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccBytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccBytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        status = avccBytes.withUnsafeBufferPointer { buf in
            CMBlockBufferReplaceDataBytes(
                with: buf.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccBytes.count
            )
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsMillis, timescale: 1000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccBytes.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
